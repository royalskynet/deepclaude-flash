#!/usr/bin/env node
// Self-check for the main-loop harness + loop guard (no framework, no fixtures).
// Run: node proxy/test-loop-guard.mjs
import assert from 'assert';
import { createServer } from 'http';
import { writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

const MAIN = 'deepseek-v4-flash-0731';
const harnessFile = join(tmpdir(), `dc-main-harness-${process.pid}.md`);
writeFileSync(harnessFile, 'MAIN HARNESS MARKER');

process.env.DC_MODEL = MAIN;
process.env.DC_SUBAGENT_MODEL = '';          // single-model: deep-run has no Agent tool
process.env.DC_MAIN_HARNESS_FILE = harnessFile;
process.env.DC_LOOP_GUARD = 'on';
process.env.DC_GUARD_SINGLES = '3';
process.env.DC_GUARD_NARRATION = '100';   // production default is 4 / 3000 / 15
process.env.DC_GUARD_ROUNDS = '15';

const seen = [];
const CATALOG = [
    { id: MAIN, context_length: 1048576, max_output_tokens: 65536, capabilities: { reasoning: true } },
];

const upstream = createServer((req, res) => {
    // The proxy probes the provider catalog on startup; answer it the way a real
    // backend does, so the max_tokens clamp under test sees genuine caps.
    if (req.url === '/v1/models') {
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

const { startModelProxy } = await import('./model-proxy.js');
const { port } = await startModelProxy({
    targetUrl: `http://127.0.0.1:${upstream.address().port}`,
    apiKey: 'test', startPort: 0, defaultMode: '_single',
});

const post = (body) => fetch(`http://127.0.0.1:${port}/v1/messages`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-api-key': 'test' },
    body: JSON.stringify(body),
});
const sysOf = (b) => (typeof b.system === 'string' ? b.system : (b.system || []).map((p) => p.text).join('\n'));
// The proxy folds late system messages into user text (foldLateSystemMessages),
// so a nudge arrives upstream as a <system-reminder> block, not a role:system message.
const nudge = (b) => (b.messages || []).flatMap((m) => (Array.isArray(m.content) ? m.content : []))
    .map((c) => /^<system-reminder>\n([\s\S]*)\n<\/system-reminder>$/.exec(c.text || '')?.[1]).filter(Boolean).join(' ');

// Build a conversation: `turns` assistant turns, each firing `tools` tool_use
// blocks. `cmd` is the shell string in each block — the guard counts the commands
// inside it, not the blocks, so this is what separates a batch from a single.
const convo = (turns, tools, text = '', cmd = '') => {
    const messages = [{ role: 'user', content: 'go' }];
    for (let i = 0; i < turns; i++) {
        const content = [];
        if (text) content.push({ type: 'text', text });
        for (let t = 0; t < tools; t++) {
            content.push({ type: 'tool_use', id: `t${i}${t}`, name: 'Bash', input: cmd ? { command: cmd } : {} });
        }
        messages.push({ role: 'assistant', content });
        messages.push({ role: 'user', content: [{ type: 'tool_result', tool_use_id: `t${i}0`, content: 'ok' }] });
    }
    return messages;
};

// 1. The main loop gets the harness it opted into.
await post({ model: MAIN, max_tokens: 100, system: 'DEEP SYS', messages: convo(1, 2) });
assert.ok(sysOf(seen[0]).includes('MAIN HARNESS MARKER'), 'main loop must get DC_MAIN_HARNESS_FILE');
assert.ok(sysOf(seen[0]).includes('DEEP SYS'), 'original system prompt must survive');
assert.strictEqual(nudge(seen[0]), '', 'a healthy 2-tool round must not be nudged');

// 2. Three consecutive single-tool rounds trip the batching nudge.
await post({ model: MAIN, max_tokens: 100, system: 'S', messages: convo(3, 1) });
assert.ok(nudge(seen[1]).includes('一次全部發完'), 'three single-tool rounds must trip the batch nudge');

// 3. Two are still under the threshold.
await post({ model: MAIN, max_tokens: 100, system: 'S', messages: convo(2, 1) });
assert.strictEqual(nudge(seen[2]), '', 'two single-tool rounds must stay silent');

// 4. A batched round resets the run.
const mixed = convo(3, 1).concat(convo(1, 2).slice(1));
await post({ model: MAIN, max_tokens: 100, system: 'S', messages: mixed });
assert.ok(!nudge(seen[3]).includes('一次全部發完'), 'a batched round must reset the single-tool run');

// 5. Narration over budget trips the terse nudge.
await post({ model: MAIN, max_tokens: 100, system: 'S', messages: convo(2, 2, 'x'.repeat(80)) });
assert.ok(nudge(seen[4]).includes('只貼指令與原始輸出'), 'narration over budget must trip the terse nudge');

// 6. Round 15 trips the converge-or-stop nudge.
await post({ model: MAIN, max_tokens: 100, system: 'S', messages: convo(15, 2) });
assert.ok(nudge(seen[5]).includes('NOT DONE'), 'round 15 must trip the convergence nudge');

// 7. The nudge is appended as the last block of the last user turn (folded from a
//    system message) — never a mutation of the assistant history the client owns.
const before = convo(3, 1);
await post({ model: MAIN, max_tokens: 100, system: 'S', messages: before });
const fwd = seen[6].messages;
assert.deepStrictEqual(fwd.slice(0, before.length - 1), before.slice(0, -1), 'client history must be forwarded untouched');
const last = fwd[fwd.length - 1].content;
assert.deepStrictEqual(last.slice(0, -1), before[before.length - 1].content, 'last user turn keeps its own blocks');
assert.match(last[last.length - 1].text, /^<system-reminder>/, 'the nudge must be appended last');

// 8. One Bash call that chains commands is already batched — counting tool_use
//    blocks called this a "single-tool round" and nudged it; counting shell units
//    does not. This is the 88.8% → 35.8% correction the thresholds now rest on.
await post({ model: MAIN, max_tokens: 100, system: 'S', messages: convo(3, 1, '', 'git status; git log -1; git diff') });
assert.strictEqual(nudge(seen[7]), '', 'a ;-chained Bash call must count as batched, not single');
await post({ model: MAIN, max_tokens: 100, system: 'S', messages: convo(3, 1, '', 'a && b || c') });
assert.strictEqual(nudge(seen[8]), '', '&& and || must separate units too');

// 9. Separators that are data, not syntax, must not fake a batch.
await post({ model: MAIN, max_tokens: 100, system: 'S', messages: convo(3, 1, '', 'echo "a; b; c"') });
assert.ok(nudge(seen[9]).includes('一次全部發完'), 'a quoted ; must not count as a separator');
await post({ model: MAIN, max_tokens: 100, system: 'S', messages: convo(3, 1, '', 'cat <<EOF\na; b\nc && d\nEOF') });
assert.ok(nudge(seen[10]).includes('一次全部發完'), 'a heredoc body must not count as separators');

// 10. The narration nudge fires once per doubling band, not on every round after
//     the first crossing — the original `narration >= budget` never stopped firing.
await post({ model: MAIN, max_tokens: 100, system: 'S', messages: convo(4, 2, 'x'.repeat(30)) });
assert.ok(nudge(seen[11]).includes('只貼指令與原始輸出'), 'crossing the narration band must nudge');
await post({ model: MAIN, max_tokens: 100, system: 'S', messages: convo(5, 2, 'x'.repeat(30)) });
assert.strictEqual(nudge(seen[12]), '', 'staying inside the same narration band must stay silent');

// 11. The round nudge escalates rather than repeating. Repetition is what an ignored
//     nudge looks like: 8/78 corpus sessions would get four or more identical ones.
await post({ model: MAIN, max_tokens: 100, system: 'S', messages: convo(30, 2) });
assert.ok(nudge(seen[13]).includes('二選一'), 'the 2nd round nudge still offers the choice');
await post({ model: MAIN, max_tokens: 100, system: 'S', messages: convo(45, 2) });
assert.ok(nudge(seen[14]).includes('第 3 次') && !nudge(seen[14]).includes('二選一'),
    'the 3rd round nudge escalates and stops offering a choice');

console.log('OK: 15/15 loop-guard checks passed');
process.exit(0);
