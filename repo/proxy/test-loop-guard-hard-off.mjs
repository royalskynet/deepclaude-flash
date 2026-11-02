#!/usr/bin/env node
// Self-check: DC_GUARD_HARD=off (interactive launchers) drops only the 90-round hard
// stop; the batching nudge still fires. Run: node proxy/test-loop-guard-hard-off.mjs
import assert from 'assert';
import { createServer } from 'http';

const MAIN = 'deepseek-v4-flash-0731';
process.env.DC_MODEL = MAIN;
process.env.DC_SUBAGENT_MODEL = '';
process.env.DC_LOOP_GUARD = 'on';
process.env.DC_GUARD_HARD = 'off';

const seen = [];
const upstream = createServer((req, res) => {
    if (req.url === '/v1/models') {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ models: [{ id: MAIN, context_length: 1048576, max_output_tokens: 65536 }] }));
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

const { startModelProxy } = await import('./model-proxy.js');
const { port } = await startModelProxy({
    targetUrl: `http://127.0.0.1:${upstream.address().port}`,
    apiKey: 'test', startPort: 0, defaultMode: '_single',
});
const post = (body) => fetch(`http://127.0.0.1:${port}/v1/messages`, {
    method: 'POST', headers: { 'content-type': 'application/json', 'x-api-key': 'test' }, body: JSON.stringify(body),
});
const nudge = (b) => (b.messages || []).flatMap((m) => (Array.isArray(m.content) ? m.content : []))
    .map((c) => /^<system-reminder>\n([\s\S]*)\n<\/system-reminder>$/.exec(c.text || '')?.[1]).filter(Boolean).join(' ');
const convo = (turns, tools) => {
    const messages = [{ role: 'user', content: 'go' }];
    for (let i = 0; i < turns; i++) {
        const content = [];
        for (let t = 0; t < tools; t++) content.push({ type: 'tool_use', id: `t${i}${t}`, name: 'Bash', input: {} });
        messages.push({ role: 'assistant', content });
        messages.push({ role: 'user', content: [{ type: 'tool_result', tool_use_id: `t${i}0`, content: 'ok' }] });
    }
    return messages;
};

await post({ model: MAIN, max_tokens: 100, system: 'S', messages: convo(90, 2) });
assert.ok(!nudge(seen[0]).includes('NOT DONE'), 'DC_GUARD_HARD=off must not force the 90-round report');
await post({ model: MAIN, max_tokens: 100, system: 'S', messages: convo(4, 1) });
assert.ok(nudge(seen[1]).includes('一次全部發完'), 'the batching nudge must stay on');

console.log('OK: 2/2 hard-off checks passed');
process.exit(0);
