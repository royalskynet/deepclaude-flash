#!/usr/bin/env node
import { startModelProxy } from './model-proxy.js';

const BACKEND_DEFS = {
    deepseek: { url: 'https://api.deepseek.com/anthropic', keyEnv: 'DEEPSEEK_API_KEY' },
    openrouter: { url: 'https://openrouter.ai/api/v1', keyEnv: 'OPENROUTER_API_KEY' },
    fireworks: { url: 'https://api.fireworks.ai/inference/v1', keyEnv: 'FIREWORKS_API_KEY' },
};

// Legacy mode: start-proxy.js <targetUrl> <apiKey> [--port N] (used by deepclaude.sh/ps1
// and bin/deepclaude-proxyd)
const targetUrl = process.argv[2] || process.env.CHEAPCLAUDE_TARGET_URL;
const apiKey = process.argv[3] || process.env.CHEAPCLAUDE_API_KEY;
const legacyPortFlag = process.argv.indexOf('--port');
const legacyPort = legacyPortFlag >= 0 ? parseInt(process.argv[legacyPortFlag + 1], 10) : undefined;

if (targetUrl && apiKey) {
    // Legacy single-backend mode
    const backends = {};
    for (const [name, def] of Object.entries(BACKEND_DEFS)) {
        const key = process.env[def.keyEnv];
        if (key) backends[name] = { url: def.url, apiKey: key };
    }
    const hasBackends = Object.keys(backends).length > 0;

    const { port } = await startModelProxy({
        targetUrl,
        apiKey,
        startPort: legacyPort,
        backends: hasBackends ? backends : undefined,
        // Always start on the CLI-given target. Without this, any extra *_API_KEY in the
        // environment (e.g. OPENROUTER_API_KEY loaded for another backend) made the proxy
        // boot in 'anthropic' passthrough mode and send every request to api.anthropic.com.
        // The backends map only serves /_proxy/mode switching.
        defaultMode: '_single',
    });
    console.log(port);
} else {
    // Standalone mode with live toggle
    const backends = {};
    for (const [name, def] of Object.entries(BACKEND_DEFS)) {
        const key = process.env[def.keyEnv];
        backends[name] = { url: def.url, apiKey: key || null };
    }

    const fallbackUrl = backends.deepseek?.url || 'https://api.deepseek.com/anthropic';
    const fallbackKey = backends.deepseek?.apiKey || 'unused';

    const args = process.argv.slice(2);
    const modeFlag = args.indexOf('--mode');
    const defaultMode = modeFlag >= 0 ? args[modeFlag + 1] : 'anthropic';
    const portFlag = args.indexOf('--port');
    const port = portFlag >= 0 ? parseInt(args[portFlag + 1], 10) : 3200;

    const proxy = await startModelProxy({
        targetUrl: fallbackUrl,
        apiKey: fallbackKey,
        startPort: port,
        backends,
        defaultMode,
    });

    console.log(`Proxy on :${proxy.port} (mode: ${defaultMode})`);
    console.log(`Switch: curl -sX POST http://127.0.0.1:${proxy.port}/_proxy/mode -d backend=deepseek`);
    console.log(`Status: curl -s http://127.0.0.1:${proxy.port}/_proxy/status`);
}
