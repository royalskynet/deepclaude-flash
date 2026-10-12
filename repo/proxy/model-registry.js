/**
 * Per-model capabilities, read from the provider instead of hardcoded here.
 *
 * Every backend this proxy talks to publishes GET /v1/models with the output cap,
 * context window, reasoning support and current price of each model it serves.
 * Copying those numbers into a `case` statement is what produced two separate
 * defects: a new model id falling through a catch-all and losing 87% of its output
 * budget, and pinned net prices going stale (the
 * cheaperinference catalog stamps each price with an expiresAt roughly ten minutes
 * out, so a number copied at noon is wrong by lunch).
 *
 * Also usable as a CLI, which is how deepclaude.sh gets the same numbers:
 *   node model-registry.js <base-url> <api-key> <model-id>   → shell assignments
 */
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { writeFileSync, readFileSync, mkdirSync } from 'fs';
import { homedir } from 'os';
import { join } from 'path';

const CACHE_DIR = join(homedir(), '.deepclaude', 'cache');
const TTL_MS = 60 * 60 * 1000;

/** Coerce the three shapes these backends use into one flat entry. */
export function normalize(raw) {
    const out = {};
    // cheaperinference says `models`, OpenAI-compatible backends say `data`.
    for (const m of raw.models || raw.data || []) {
        if (!m?.id) continue;
        const p = m.pricing || {};
        const num = (v) => (v == null || v === '' ? null : Number(v));
        out[m.id] = {
            // OpenRouter reports the output cap one level down, under the provider.
            max_output_tokens: m.max_output_tokens ?? m.top_provider?.max_completion_tokens ?? null,
            max_input_tokens: m.context_length ?? m.top_provider?.context_length ?? null,
            // OpenRouter has no capabilities object; the parameters it accepts are
            // the more reliable signal anyway, since they track the live deployment.
            supports_reasoning: m.capabilities?.reasoning
                ?? (Array.isArray(m.supported_parameters)
                    ? m.supported_parameters.includes('reasoning')
                    : null),
            // Per-million, already net of any discount. OpenRouter quotes per-token.
            input_per_m: num(p.input_per_million) ?? (num(p.prompt) != null ? num(p.prompt) * 1e6 : null),
            output_per_m: num(p.output_per_million) ?? (num(p.completion) != null ? num(p.completion) * 1e6 : null),
            cache_read_per_m: num(p.cache_read_input_per_million)
                ?? (num(p.input_cache_read) != null ? num(p.input_cache_read) * 1e6 : null),
        };
    }
    return out;
}

function cachePath(baseUrl) {
    return join(CACHE_DIR, `models-${new URL(baseUrl).host}.json`);
}

function readCache(baseUrl, { ignoreAge = false } = {}) {
    try {
        const c = JSON.parse(readFileSync(cachePath(baseUrl), 'utf8'));
        if (ignoreAge || Date.now() - c.fetchedAt < TTL_MS) return c.entries;
    } catch { /* no cache yet, or corrupt — refetch */ }
    return null;
}

/**
 * Entries for one backend. Never throws: a backend that cannot answer leaves the
 * clamp disabled (caps stay unknown) rather than substituting invented limits.
 */
export async function loadRegistry(baseUrl, apiKey) {
    const fresh = readCache(baseUrl);
    if (fresh) return makeRegistry(fresh);

    let entries;
    try {
        const url = new URL('/v1/models', baseUrl);
        const res = await fetch(url, {
            headers: { Authorization: `Bearer ${apiKey}`, 'x-api-key': apiKey },
            signal: AbortSignal.timeout(10_000),
        });
        if (!res.ok) throw new Error(`${url} → HTTP ${res.status}`);
        entries = normalize(await res.json());
        mkdirSync(CACHE_DIR, { recursive: true });
        writeFileSync(cachePath(baseUrl), JSON.stringify({ fetchedAt: Date.now(), entries }));
    } catch (e) {
        // Stale beats nothing: caps and context windows move far more slowly than
        // prices, so an hour-old catalog is still a better clamp than no clamp.
        entries = readCache(baseUrl, { ignoreAge: true });
        if (!entries) throw e;
        console.error(`[MODEL-REGISTRY] using stale catalog for ${new URL(baseUrl).host}: ${e.message}`);
    }
    return makeRegistry(entries);
}

function makeRegistry(entries) {
    // Local overrides, for a model the provider misreports or has not listed yet.
    let overrides = {};
    try {
        overrides = JSON.parse(readFileSync(new URL('./models.local.json', import.meta.url), 'utf8'));
    } catch { /* optional file */ }

    return {
        entries,
        lookup(id) {
            if (!id) return null;
            // Providers prefix inconsistently (`z-ai/glm-5.3-flash` vs `glm-5.3-flash`),
            // so fall back to the last path segment before giving up.
            // Claude Code appends a context-window suffix to model ids it was told to
            // use (`glm-5.3-flash[1m]`); the catalog never carries one, so strip it.
            const bare = id.replace(/\[[^\]]*\]$/, '');
            const keys = [id, bare, bare.split('/').pop()];
            for (const k of keys) {
                if (overrides[k] || entries[k]) return { ...entries[k], ...overrides[k] };
            }
            return null;
        },
    };
}

// CLI: emit shell assignments for deepclaude.sh, or exit 1 on an unknown model.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    const [baseUrl, argKey, model] = process.argv.slice(2);
    // Key via env, never argv: `ps` output landed the value in 7 session transcripts
    // (2026-09-12..16 audit). Same shape as bin/deepclaude-proxyd.
    const apiKey = argKey || process.env.CHEAPCLAUDE_API_KEY;
    const reg = await loadRegistry(baseUrl, apiKey).catch((e) => {
        console.error(`[MODEL-REGISTRY] ${e.message}`);
        process.exit(1);
    });
    const e = reg.lookup(model);
    if (!e?.max_output_tokens) process.exit(1);
    const sh = (k, v) => console.log(`${k}=${v ?? ''}`);
    sh('DC_MAX_OUTPUT', e.max_output_tokens);
    sh('DC_MAX_INPUT', e.max_input_tokens);
    sh('DC_IN_PER_M', e.input_per_m);
    sh('DC_OUT_PER_M', e.output_per_m);
    sh('DC_CACHE_READ_PER_M', e.cache_read_per_m);
    sh('DC_SUPPORTS_REASONING', e.supports_reasoning ? 1 : 0);
}
