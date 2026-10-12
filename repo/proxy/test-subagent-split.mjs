#!/usr/bin/env node
// Self-check for the Pro/Flash subagent split (no framework, no fixtures).
// Run: node proxy/test-subagent-split.mjs
import assert from 'assert';
import { createServer } from 'http';

const MAIN = 'deepseek-v4-pro-0813';
const SUB = 'deepseek-v4-flash-0731';

process.env.DC_MODEL = MAIN;
process.env.DC_SUBAGENT_MODEL = SUB;
process.env.DC_SUBAGENT_MAX_OUTPUT = '65536';

// Fake upstream: echo back whatever body the proxy forwarded.
const seen = [];
let catalogHits = 0;
const CATALOG = [
    { id: MAIN, context_length: 1048576, max_output_tokens: 384000, capabilities: { reasoning: true } },
    { id: SUB, context_length: 1048576, max_output_tokens: 65536, capabilities: { reasoning: true } },
];

const upstream = createServer((req, res) => {
    // The proxy probes the provider catalog on startup; answer it the way a real
    // backend does, so the max_tokens clamp under test sees genuine caps.
    if (req.url === '/v1/models') {
        catalogHits++;
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ models: CATALOG }));
        return;
    }

    let buf = '';
    req.on('data', (c) => { buf += c; });
    req.on('end', () => {
        seen.push(JSON.parse(buf));
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ id: 'x', type: 'message', role: 'assistant', content: [], usage: { input_tokens: 1, output_tokens: 1 } }));
    });
});
await new Promise((r) => upstream.listen(0, '127.0.0.1', r));
const upstreamUrl = `http://127.0.0.1:${upstream.address().port}`;

const { startModelProxy } = await import('./model-proxy.js');
const { port } = await startModelProxy({ targetUrl: upstreamUrl, apiKey: 'test', startPort: 0, defaultMode: '_single' });

const post = (body) => fetch(`http://127.0.0.1:${port}/v1/messages`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-api-key': 'test' },
    body: JSON.stringify(body),
});

const sysOf = (b) => (typeof b.system === 'string' ? b.system : (b.system || []).map((p) => p.text).join('\n'));

// 1. Main-loop traffic (any non-subagent id) lands on Pro, untouched system.
await post({ model: 'claude-opus-4-8', max_tokens: 384000, system: 'MAIN SYS', messages: [] });
assert.strictEqual(seen[0].model, MAIN, 'main request must remap to Pro');
assert.strictEqual(seen[0].max_tokens, 384000, 'main request must keep its max_tokens');
assert.ok(!sysOf(seen[0]).includes('lazy senior developer'), 'harness must not touch the main loop');

// 2. Subagent traffic stays on Flash, gets the harness, and is clamped.
await post({ model: SUB, max_tokens: 384000, system: 'SUB SYS', messages: [] });
assert.strictEqual(seen[1].model, SUB, 'subagent request must stay on Flash');
assert.strictEqual(seen[1].max_tokens, 65536, 'subagent max_tokens must be clamped to Flash cap');
assert.ok(sysOf(seen[1]).includes('lazy senior developer'), 'subagent must get the ponytail harness');
assert.ok(sysOf(seen[1]).includes('SUB SYS'), 'original subagent system prompt must survive');

// 3. A client sending a hardcoded haiku id (happy) is treated as a subagent.
await post({ model: 'claude-haiku-4-5-20251001', max_tokens: 200000, system: [{ type: 'text', text: 'BLOCK SYS' }], messages: [] });
assert.strictEqual(seen[2].model, SUB, 'haiku-class id must route to Flash');
assert.strictEqual(seen[2].max_tokens, 65536, 'haiku-class request must be clamped');
assert.ok(sysOf(seen[2]).includes('lazy senior developer'), 'block-array system must get the harness');

// 4. Harness is not injected twice when the client replays it.
await post({ model: SUB, max_tokens: 1000, system: sysOf(seen[1]), messages: [] });
const hits = sysOf(seen[3]).split('lazy senior developer').length - 1;
assert.strictEqual(hits, 1, 'harness must not be injected twice');

// 5. The main model is clamped too, from the catalog rather than from an env
// var — Claude Code sends one max_tokens sized for the largest model it knows,
// and a backend 400s on anything above its own cap.
await post({ model: 'claude-opus-4-8', max_tokens: 999999, system: 'MAIN SYS', messages: [] });
assert.strictEqual(seen[4].model, MAIN);
assert.strictEqual(seen[4].max_tokens, 384000, 'main max_tokens must be clamped to the catalog cap');

// 6. A client SDK catalog query (GET /v1/models, query_source:sdk) must reach the
// backend, not the Anthropic fallback — at the fallback the deepseek id is absent,
// so every request logs `unrecognized_model` (issue #23).
const before = catalogHits;
const catalogRes = await fetch(`http://127.0.0.1:${port}/v1/models`, {
    headers: { 'x-api-key': 'test' },
});
assert.strictEqual(catalogRes.status, 200, 'catalog query must succeed');
assert.strictEqual(catalogHits, before + 1, 'catalog query must reach the backend, not the fallback');
const catalog = await catalogRes.json();
assert.ok(Array.isArray(catalog.models ?? catalog.data), 'catalog response must be the backend model list');

console.log('OK: 6/6 subagent-split checks passed');
process.exit(0);
