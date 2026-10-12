#!/usr/bin/env node
// Self-check for foldLateSystemMessages: the prefix before the newest turn must be
// byte-identical across turns, or CheaperInference re-prefills everything after it.
// Run: node proxy/test-fold-system.mjs
import assert from 'assert';
import { foldLateSystemMessages } from './model-proxy.js';

const tu = (id) => ({ role: 'assistant', content: [{ type: 'tool_use', id, name: 'Bash', input: {} }] });
const tr = (id) => ({ role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content: 'ok' }] });
const turn = (n) => {
    const m = [{ role: 'user', content: 'go' }, { role: 'system', content: 'ENV' }];
    for (let i = 0; i < n; i++) m.push(tu(`t${i}`), tr(`t${i}`), { role: 'system', content: `<total_tokens>${1000 - i}</total_tokens>` });
    return { messages: m };
};

// 1. Early system (before first assistant) stays for the backend to hoist.
const a = turn(2); foldLateSystemMessages(a);
assert.deepStrictEqual(a.messages[1], { role: 'system', content: 'ENV' });
// 2. No late role:system survives; each lands on the tool_result it followed.
assert.strictEqual(a.messages.filter((m) => m.role === 'system').length, 1);
assert.match(a.messages[3].content[1].text, /^<system-reminder>\n<total_tokens>1000/);
// 3. Turn N's messages are a strict prefix of turn N+1's — the cache property.
const b = turn(3); foldLateSystemMessages(b);
assert.deepStrictEqual(b.messages.slice(0, a.messages.length), a.messages);
// 4. System right after an assistant message merges into the next user message.
const c = { messages: [{ role: 'user', content: 'go' }, tu('x'), { role: 'system', content: 'S' }, tr('x')] };
foldLateSystemMessages(c);
assert.deepStrictEqual(c.messages.map((m) => m.role), ['user', 'assistant', 'user']);
assert.strictEqual(c.messages[2].content[0].text, '<system-reminder>\nS\n</system-reminder>');
assert.strictEqual(c.messages[2].content[1].type, 'tool_result');
// 5. Trailing system after assistant becomes its own user message; no assistant → untouched.
const d = { messages: [{ role: 'user', content: 'go' }, tu('y'), { role: 'system', content: 'T' }] };
foldLateSystemMessages(d);
assert.deepStrictEqual(d.messages[2], { role: 'user', content: [{ type: 'text', text: '<system-reminder>\nT\n</system-reminder>' }] });
const e = { messages: [{ role: 'user', content: 'go' }, { role: 'system', content: 'Z' }] };
assert.strictEqual(foldLateSystemMessages(e), 0);
console.log('OK: fold-system 5 checks passed');
