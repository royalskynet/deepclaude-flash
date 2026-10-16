// Guards the two things that silently break: a schema the normalizer stops
// recognising, and a model id whose cap goes missing. Run: node test-model-registry.mjs
import assert from 'assert';
import { writeFileSync, mkdirSync } from 'fs';
import { homedir } from 'os';
import { join } from 'path';
import { normalize, loadRegistry } from './model-registry.js';

// cheaperinference shape: `models`, caps at top level, prices per million.
const ci = normalize({ models: [{
    id: 'glm-5.3-flash', context_length: 1048576, max_output_tokens: 131072,
    capabilities: { reasoning: true },
    pricing: { input_per_million: '0.105000', output_per_million: '0.350000', cache_read_input_per_million: '0.021' },
}] });
assert.strictEqual(ci['glm-5.3-flash'].max_output_tokens, 131072);
assert.strictEqual(ci['glm-5.3-flash'].cache_read_per_m, 0.021);
assert.strictEqual(ci['glm-5.3-flash'].supports_reasoning, true);

// OpenRouter shape: `data`, cap under top_provider, prices per token.
const or = normalize({ data: [{
    id: 'z-ai/glm-5.3', context_length: 200000,
    top_provider: { max_completion_tokens: 96000 },
    supported_parameters: ['tools', 'reasoning'],
    pricing: { prompt: '0.0000006', completion: '0.0000022', input_cache_read: '0.00000012' },
}] });
assert.strictEqual(or['z-ai/glm-5.3'].max_output_tokens, 96000);
assert.strictEqual(or['z-ai/glm-5.3'].input_per_m, 0.6);
assert.strictEqual(or['z-ai/glm-5.3'].supports_reasoning, true);

// A backend that reports no caps must yield null, never a guessed number —
// the clamp treats null as "no cap" and a guess as truth (fixindex 9500).
const bare = normalize({ data: [{ id: 'mystery-1' }] });
assert.strictEqual(bare['mystery-1'].max_output_tokens, null);
assert.strictEqual(bare['mystery-1'].supports_reasoning, null);

// lookup(): prefixed id resolves via its last segment; unknown id stays null.
mkdirSync(join(homedir(), '.deepclaude', 'cache'), { recursive: true });
writeFileSync(join(homedir(), '.deepclaude', 'cache', 'models-registry.test.json'),
    JSON.stringify({ fetchedAt: Date.now(), entries: ci }));
const reg = await loadRegistry('https://registry.test', 'no-key');   // cache hit, no network
assert.strictEqual(reg.lookup('vendor/glm-5.3-flash').max_output_tokens, 131072);
assert.strictEqual(reg.lookup('never-heard-of-it'), null);
assert.strictEqual(reg.lookup(undefined), null);


// Claude Code tags ids with a context-window suffix; the catalog has no such key.
assert.equal(reg.lookup('glm-5.3-flash[1m]')?.max_output_tokens, 131072, '[1m] suffix stripped');
assert.equal(reg.lookup('z-ai/glm-5.3-flash[1m]')?.max_output_tokens, 131072, 'prefix+suffix stripped');
console.log('model-registry: 13 assertions OK');
