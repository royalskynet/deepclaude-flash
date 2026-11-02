#!/usr/bin/env node
// Self-check: effectiveRounds keeps rounds cumulative across a compact.
// Run: node proxy/test-loop-guard-compact.mjs
import assert from 'assert';
import { effectiveRounds } from './model-proxy.js';

const st = () => ({ last: 0, offset: 0 });
let n = 0, passed = 0;
const check = (name, fn) => {
    n++;
    try { fn(); passed++; console.log(`ok ${n} - ${name}`); }
    catch (e) { console.log(`not ok ${n} - ${name}: ${e.message}`); }
};

check('80 then compact to 10 = 90', () => {
    const s = st();
    assert.equal(effectiveRounds(s, 80), 80);
    assert.equal(effectiveRounds(s, 10), 90);
});

check('80→5→60→3 monotonic, last ≥ 143', () => {
    const s = st();
    const seq = [80, 5, 60, 3].map((r) => effectiveRounds(s, r));
    let prev = -1;
    for (const v of seq) { assert.ok(v >= prev, `decrease ${seq}`); prev = v; }
    assert.equal(seq[0], 80);
    assert.equal(seq[1], 85);
    assert.equal(seq[2], 140);
    assert.equal(seq[3], 143);
    assert.ok(seq[3] >= 143, `last ${seq[3]}`);
});

check('no compact: 10,11,12 pass through', () => {
    const s = st();
    assert.equal(effectiveRounds(s, 10), 10);
    assert.equal(effectiveRounds(s, 11), 11);
    assert.equal(effectiveRounds(s, 12), 12);
});

if (passed !== n) { console.log(`FAIL: ${passed}/${n} compact checks passed`); process.exit(1); }
console.log(`OK: ${passed}/${n} compact checks passed`);
