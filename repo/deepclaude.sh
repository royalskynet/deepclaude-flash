#!/usr/bin/env bash
# deepclaude — Use Claude Code with DeepSeek Flash or other cheap backends
# Usage: deepclaude [--backend ds|or|fw|anthropic] [--remote] [--status] [--cost] [--benchmark]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Config ---
DEEPSEEK_URL="https://api.deepseek.com/anthropic"
OPENROUTER_URL="https://openrouter.ai/api"
FIREWORKS_URL="https://api.fireworks.ai/inference"
CHEAPERINFERENCE_DEFAULT_URL="https://api.cheaperinference.com"
# 2026-10-12: owner switched to Flash-only (Pro refused). History below explains why
# Pro was the default before; expect longer thinking per call on Flash.
# Was: deepseek-v4-pro-0813 (reverted 2026-09-24 evening). The v4.1-flash
# pick below came from one small task; in long agent loops v4.1-flash emits
# ~3.5x more thinking per call than pro-0813 (4.6k vs 1.3k chars, same prompt,
# thinking:disabled ignored by CI's Anthropic endpoint) and real sessions
# stalled 82-165s/call.
# Earlier A/B (kept for history):
# tools/ab-model.sh, 3 trials each on one fixed task, 2026-09-24:
#   glm-5.3-flash       wall 45-53s  median TTFB 17.1s  $0.0071-0.0141
#   deepseek-v4.1-flash wall 25-32s  median TTFB  8.5s  $0.0121-0.0229
# Every v4.1 run beat every GLM run on latency (~1.9x wall, ~2x TTFB) at equal
# answer quality. It costs a little more per task and the cost ranges overlap,
# so the gap is not established -- about half a cent on a task either way.
# It also keeps max_out at 384000 where GLM drops to 131072.
# Note the earlier prediction that v4.1 would be ~2.7x CHEAPER was wrong: that
# came from its 8x cheaper cache-read rate, but it earns far fewer cache hits,
# so the cheaper rate never gets applied. Prices move hourly; re-run the A/B
# rather than trusting these numbers.
# 2026-10-12: owner policy — DeepSeek Flash only, never Pro (guard in resolve_backend).
CI_MODEL="${CHEAPERINFERENCE_MODEL:-deepseek-v4-flash-0731}"
# Subagents stay on DeepSeek V4 Flash: still 1.6x cheaper input / 2.7x cheaper
# output than the GLM main loop ($0.0646/$0.130 vs $0.105/$0.350 per M). The
# quality gap is covered by the ponytail harness in repo/proxy/subagent-harness.md.
CI_SUBAGENT_MODEL="${CHEAPERINFERENCE_SUBAGENT_MODEL:-deepseek-v4-flash-0731}"
# max_output of the subagent model; the proxy clamps subagent requests to it so
# the main model's CLAUDE_CODE_MAX_OUTPUT_TOKENS never overflows Flash's 65536 cap.
CI_SUBAGENT_MAX_OUTPUT="${CHEAPERINFERENCE_SUBAGENT_MAX_OUTPUT:-65536}"
OMNIROUTE_DEFAULT_URL="http://127.0.0.1:20128"
# OpenCode Go subscription: Anthropic /v1/messages under /zen/go; the proxy adds the
# x-opencode-session header Go requires (400 MissingSessionID without it).
OPENCODE_GO_URL="https://opencode.ai/zen/go"
GO_MODEL="${OPENCODE_GO_MODEL:-deepseek-v4-flash}"
OMNI_MODEL="${OMNIROUTE_MODEL:-free-tools}"

BACKEND="${CHEAPCLAUDE_DEFAULT_BACKEND:-ci}"
ACTION="launch"
SWITCH_BACKEND=""
PROXY_PID=""

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend|-b) BACKEND="$2"; shift 2 ;;
        --switch|-s)  ACTION="switch"; SWITCH_BACKEND="$2"; shift 2 ;;
        --remote|-r)  ACTION="remote"; shift ;;
        --status)     ACTION="status"; shift ;;
        --cost)       ACTION="cost"; shift ;;
        --benchmark)  ACTION="benchmark"; shift ;;
        --happy)      ACTION="happy"; shift ;;
        --restart)    ACTION="restart"; shift ;;
        --help|-h)    ACTION="help"; shift ;;
        *)            break ;;
    esac
done

cleanup_proxy() {
    if [[ -n "$PROXY_PID" ]] && kill -0 "$PROXY_PID" 2>/dev/null; then
        kill "$PROXY_PID" 2>/dev/null || true
        echo "  Proxy stopped."
    fi
}
trap cleanup_proxy EXIT

mask_key() {
    local k="$1"
    if [[ -z "$k" ]]; then echo "MISSING"; else echo "set (****${k: -4})"; fi
}

resolve_backend() {
    local url="" key="" opus="" sonnet="" haiku="" subagent="" sub_max_out=""
    case "$BACKEND" in
        ds|deepseek)
            key="${DEEPSEEK_API_KEY:-}"
            [[ -z "$key" ]] && { echo "ERROR: DEEPSEEK_API_KEY not set" >&2; exit 1; }
            url="$DEEPSEEK_URL"
            opus="deepseek-v4-flash"; sonnet="deepseek-v4-flash"
            haiku="deepseek-v4-flash"; subagent="deepseek-v4-flash"
            ;;
        or|openrouter)
            key="${OPENROUTER_API_KEY:-}"
            [[ -z "$key" ]] && { echo "ERROR: OPENROUTER_API_KEY not set" >&2; exit 1; }
            url="$OPENROUTER_URL"
            opus="${OPENROUTER_MODEL:-deepseek/deepseek-v4-flash-0731}"; sonnet="$opus"
            haiku="$opus"; subagent="$opus"  # deep-or
            ;;
        fw|fireworks)
            key="${FIREWORKS_API_KEY:-}"
            [[ -z "$key" ]] && { echo "ERROR: FIREWORKS_API_KEY not set" >&2; exit 1; }
            url="$FIREWORKS_URL"
            opus="${FIREWORKS_MODEL:-accounts/fireworks/models/deepseek-v4-flash}"
            sonnet="$opus"; haiku="$opus"; subagent="$opus"
            ;;
        ci|cheaper|cheaperinference)
            key="${CHEAPERINFERENCE_API_KEY:-}"
            [[ -z "$key" ]] && { echo "ERROR: CHEAPERINFERENCE_API_KEY not set" >&2; exit 1; }
            url="${CHEAPERINFERENCE_URL:-$CHEAPERINFERENCE_DEFAULT_URL}"
            opus="$CI_MODEL"; sonnet="$CI_MODEL"
            haiku="$CI_SUBAGENT_MODEL"; subagent="$CI_SUBAGENT_MODEL"
            sub_max_out="$CI_SUBAGENT_MAX_OUTPUT"
            ;;
        go|opencode-go)
            key="${OPENCODE_ZEN_API_KEY:-}"
            [[ -z "$key" ]] && { echo "ERROR: OPENCODE_ZEN_API_KEY not set" >&2; exit 1; }
            url="$OPENCODE_GO_URL"
            opus="$GO_MODEL"; sonnet="$GO_MODEL"
            haiku="$GO_MODEL"; subagent="$GO_MODEL"
            ;;
        omni|omniroute)
            key="${OMNIROUTE_DEEPCLAUDE_KEY:-}"
            [[ -z "$key" ]] && { echo "ERROR: OMNIROUTE_DEEPCLAUDE_KEY not set" >&2; exit 1; }
            url="${OMNIROUTE_URL:-$OMNIROUTE_DEFAULT_URL}"
            opus="$OMNI_MODEL"; sonnet="$OMNI_MODEL"
            haiku="$OMNI_MODEL"; subagent="$OMNI_MODEL"
            ;;
        anthropic) ;;
        *) echo "ERROR: Unknown backend '$BACKEND'. Use: go, ci, omni, ds, or, fw, anthropic" >&2; exit 1 ;;
    esac
    # Flash-only policy: refuse any DeepSeek Pro id, including env overrides.
    local m
    for m in "$opus" "$sonnet" "$haiku" "$subagent"; do
        if [[ "$m" =~ [Dd]eep[Ss]eek.*[Pp]ro ]]; then
            echo "ERROR: '$m' is DeepSeek Pro; only DeepSeek Flash is allowed." >&2; exit 1
        fi
    done
    RESOLVED_URL="$url"; RESOLVED_KEY="$key"
    RESOLVED_OPUS="$opus"; RESOLVED_SONNET="$sonnet"
    RESOLVED_HAIKU="$haiku"; RESOLVED_SUBAGENT="$subagent"
    # Only set when the subagent model differs from the main one; the proxy uses
    # its presence to decide whether to split traffic across two models at all.
    if [[ -n "$subagent" && "$subagent" != "$opus" ]]; then
        RESOLVED_SUBAGENT_SPLIT="$subagent"
        RESOLVED_SUBAGENT_MAX_OUTPUT="$sub_max_out"
    else
        RESOLVED_SUBAGENT_SPLIT=""
        RESOLVED_SUBAGENT_MAX_OUTPUT=""
    fi
}

set_model_env() {
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$RESOLVED_OPUS"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$RESOLVED_SONNET"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$RESOLVED_HAIKU"
    export CLAUDE_CODE_SUBAGENT_MODEL="$RESOLVED_SUBAGENT"
    # Per-model caps come from the provider catalog (proxy/model-registry.js →
    # GET /v1/models), never from a case statement here. A hardcoded table is how
    # a past bug happened: a new model id fell through the catch-all and had
    # its 131,072 output cap silently clamped to 16,384. Unknown id now fails loud.
    # Single source of truth: do NOT also pin CLAUDE_CODE_MAX_OUTPUT_TOKENS in settings.json.
    if [[ "$BACKEND" != "anthropic" && -n "$RESOLVED_OPUS" ]]; then
        local caps
        # key 不走 argv：`ps` 全機可見
        if ! caps="$(CHEAPCLAUDE_API_KEY="$RESOLVED_KEY" node "$SCRIPT_DIR/proxy/model-registry.js" "$RESOLVED_URL" "" "$RESOLVED_OPUS")"; then
            echo "ERROR: no capability entry for '$RESOLVED_OPUS' on $RESOLVED_URL." >&2
            echo "       Fix the model id, or add an override in proxy/models.local.json." >&2
            exit 1
        fi
        eval "$caps"
        export CLAUDE_CODE_MAX_OUTPUT_TOKENS="$DC_MAX_OUTPUT"
        # Context window. Claude Code does not know these model ids, so it falls back to
        # the 200k default and the /context gauge reads several times too high.
        # autoCompactWindow does NOT drive that gauge; CLAUDE_CODE_MAX_CONTEXT_TOKENS does.
        # 40% of the real window (runbook 0815): input cost and TTFB grow linearly with
        # input, so compact earlier instead of filling the window.
        export CLAUDE_CODE_MAX_CONTEXT_TOKENS=$(( ${DC_MAX_INPUT:-1000000} * 40 / 100 ))
        # Exported for --cost, which prices a session off live catalog rates instead of
        # the net prices that used to be pinned in source and rot.
        export DC_IN_PER_M DC_OUT_PER_M DC_CACHE_READ_PER_M DC_SUPPORTS_REASONING
    fi
    export CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1
    export CLAUDE_CODE_ATTRIBUTION_HEADER="0"              # no Anthropic client attribution header
    export DISABLE_TELEMETRY="1" DISABLE_ERROR_REPORTING="1"   # 不可用 NONESSENTIAL：會連 plugin `$.http.fetch` 一起封死（fast-jev-compaction）
    export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS="1"      # no beta headers a third-party backend won't honor
    export CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING="1"       # no adaptive-thinking prompt injection
    export ENABLE_TOOL_SEARCH="false"                      # no tool_reference blocks on a third-party backend
}

show_status() {
    echo ""
    echo "  deepclaude — Backend Status"
    echo "  ============================"
    echo ""
    echo "  Keys:"
    echo "    DEEPSEEK_API_KEY:    $(mask_key "${DEEPSEEK_API_KEY:-}")"
    echo "    OPENROUTER_API_KEY:  $(mask_key "${OPENROUTER_API_KEY:-}")"
    echo "    FIREWORKS_API_KEY:   $(mask_key "${FIREWORKS_API_KEY:-}")"
    echo "    CHEAPERINFERENCE_API_KEY: $(mask_key "${CHEAPERINFERENCE_API_KEY:-}")"
    echo "    OMNIROUTE_DEEPCLAUDE_KEY: $(mask_key "${OMNIROUTE_DEEPCLAUDE_KEY:-}")"
    echo "    OPENCODE_ZEN_API_KEY:     $(mask_key "${OPENCODE_ZEN_API_KEY:-}")"
    echo "    CLAUDE_CONFIG_DIR:   ${CLAUDE_CONFIG_DIR:-<default ~/.claude>}"
    echo ""
    echo "  Backends:"
    echo "    deepclaude                  # CheaperInference (default): DeepSeek V4 Flash, main + subagents"
    echo "    deepclaude -b omni          # OmniRoute free combo (via resident proxy)"
    echo "    deepclaude -b go            # OpenCode Go subscription: DeepSeek V4 Flash"
    echo "    deepclaude -b or            # OpenRouter (cheapest)"
    echo "    deepclaude -b fw            # Fireworks AI (fastest)"
    echo "    deepclaude -b anthropic     # Normal Claude Code"
    echo "    deepclaude --remote         # Remote control + DeepSeek"
    echo "    deepclaude --remote -b or   # Remote control + OpenRouter"
    echo "    deepclaude --happy          # Launch happy against the resident proxy"
    echo "    deepclaude --restart        # Clean restart of proxy + happy (kills orphans)"
    echo ""
    local proxy_status
    proxy_status=$(curl -s http://127.0.0.1:3200/_proxy/status 2>/dev/null) || proxy_status=""
    if [[ -n "$proxy_status" ]]; then
        echo "  Proxy: running"
        echo "    $proxy_status"
    else
        echo "  Proxy: not running"
    fi
    echo ""
}

show_cost() {
    # Prices come from the provider catalog at call time. They used to be pinned
    # here and went stale within the hour: the reseller stamps every price with an
    # expiresAt about ten minutes out, and the list price itself oscillates
    # (v4-pro went 0.660 -> 1.320 -> 0.660 in one day).
    echo ""
    echo "  Pricing -- USD per million tokens, read live from GET /v1/models"
    echo "  ================================================================"
    echo ""
    if [[ "$BACKEND" != "anthropic" && -n "$RESOLVED_URL" ]]; then
        printf "  %-34s %10s %10s %12s\n" "Model" "Input" "Output" "Cache read"
        printf "  %-34s %10s %10s %12s\n" "----------------------------------" "----------" "----------" "------------"
        local m caps
        for m in "$RESOLVED_OPUS" "$RESOLVED_SUBAGENT_SPLIT"; do
            [[ -z "$m" ]] && continue
            # key 不走 argv：`ps` 全機可見
                if caps="$(CHEAPCLAUDE_API_KEY="$RESOLVED_KEY" node "$SCRIPT_DIR/proxy/model-registry.js" "$RESOLVED_URL" "" "$m" 2>/dev/null)"; then
                ( eval "$caps"
                  printf "  %-34s %10s %10s %12s\n" "$m" \
                      "\$${DC_IN_PER_M:-?}" "\$${DC_OUT_PER_M:-?}" "\$${DC_CACHE_READ_PER_M:-?}" )
            else
                printf "  %-34s %10s %10s %12s\n" "$m" "unlisted" "unlisted" "unlisted"
            fi
        done
        echo ""
        echo "  Backend: $BACKEND ($RESOLVED_URL)"
        echo "  Fetched just now; the catalog cache has a 1h TTL."
    else
        echo "  Backend '$BACKEND' publishes no catalog; see the provider's own pricing page."
    fi
    echo ""
    echo "  Anthropic direct, for reference: \$3.00 in / \$15.00 out / \$0.30 cache read"
    echo ""
}

show_help() {
    echo "deepclaude — Claude Code with cheap backends"
    echo ""
    echo "Usage: deepclaude [options] [-- claude-args...]"
    echo ""
    echo "Options:"
    echo "  -b, --backend <go|ci|omni|ds|or|fw|anthropic>  Backend (default: $CHEAPCLAUDE_DEFAULT_BACKEND)"
    echo "  -r, --remote                        Remote control mode (browser URL)"
    echo "  --happy                              Launch happy against the resident proxy"
    echo "  --status                             Show keys and backends"
    echo "  --cost                               Pricing comparison"
    echo "  --benchmark                          Latency test"
    echo "  -s, --switch <backend>               Switch proxy mid-session"
    echo "  -h, --help                           This help"
    echo ""
    echo "Environment variables:"
    echo "  DEEPSEEK_API_KEY      DeepSeek API key (required for ds)"
    echo "  OPENROUTER_API_KEY    OpenRouter API key (required for or)"
    echo "  FIREWORKS_API_KEY     Fireworks API key (required for fw)"
    echo "  OMNIROUTE_DEEPCLAUDE_KEY  OmniRoute API key (required for omni)"
    echo "  CHEAPCLAUDE_DEFAULT_BACKEND  Default backend (default: ci)"
}

do_switch() {
    local backend="$SWITCH_BACKEND"
    case "$backend" in
        ds|deepseek)   backend="deepseek" ;;
        or|openrouter) backend="openrouter" ;;
        fw|fireworks)  backend="fireworks" ;;
        anthropic)     backend="anthropic" ;;
        *) echo "ERROR: Unknown backend '$backend'. Use: ci, ds, or, fw, anthropic" >&2; exit 1 ;;
    esac
    local resp
    resp=$(curl -sX POST http://127.0.0.1:3200/_proxy/mode -d "backend=$backend" 2>/dev/null) || {
        echo "  Proxy not running. Start with: deepclaude" >&2; exit 1
    }
    echo "  $resp"
}

run_benchmark() {
    echo ""
    echo "  Latency Benchmark (1 request each)"
    echo "  ==================================="
    for name in deepseek openrouter fireworks; do
        local url="" key="" model=""
        case "$name" in
            deepseek)   url="$DEEPSEEK_URL"; key="${DEEPSEEK_API_KEY:-}"; model="deepseek-v4-flash" ;;
            openrouter) url="$OPENROUTER_URL"; key="${OPENROUTER_API_KEY:-}"; model="deepseek/deepseek-v4-flash-0731" ;;
            fireworks)  url="$FIREWORKS_URL"; key="${FIREWORKS_API_KEY:-}"; model="accounts/fireworks/models/deepseek-v4-flash" ;;
        esac
        if [[ -z "$key" ]]; then echo "  $name: SKIP (no key)"; continue; fi
        local start_ms=$(date +%s%3N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1000))')
        local status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$url/v1/messages" \
            -H "x-api-key: $key" -H "content-type: application/json" -H "anthropic-version: 2023-06-01" \
            -d "{\"model\":\"$model\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Reply: ok\"}]}" \
            --max-time 30 2>/dev/null || echo "timeout")
        local end_ms=$(date +%s%3N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1000))')
        local elapsed=$((end_ms - start_ms))
        if [[ "$status" == "200" ]]; then
            echo "  $name: OK (${elapsed}ms)"
        else
            echo "  $name: FAIL ($status, ${elapsed}ms)"
        fi
    done
    echo ""
}

launch_claude() {
    if [[ "$BACKEND" == "anthropic" ]]; then
        echo "  Launching Claude Code (normal Anthropic backend)..."
        unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN
        unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL
        unset ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL
        unset CLAUDE_CODE_EFFORT_LEVEL
        exec claude "$@"
    fi

    resolve_backend

    echo "  Launching Claude Code via $BACKEND (through model proxy)..."
    echo "  Endpoint: $RESOLVED_URL"
    echo "  Model: $RESOLVED_OPUS (main) + $RESOLVED_HAIKU (subagents)"
    echo ""

    # Route through the model proxy so it can inject `thinking:{type:disabled}`
    # (DeepSeek backends default thinking ON — that's the 4-6s TTFB tax) and
    # normalize usage. Direct-to-backend skips both.
    local port_file proxy_port
    port_file=$(mktemp "${TMPDIR:-/tmp}/deepclaude-port.XXXXXX")  # explicit template: macOS mktemp ignores TMPDIR otherwise
    DC_MODEL="$RESOLVED_OPUS" DC_SUBAGENT_MODEL="$RESOLVED_SUBAGENT_SPLIT" DC_SUBAGENT_MAX_OUTPUT="$RESOLVED_SUBAGENT_MAX_OUTPUT" DC_CLASSIFIER_MODE="${DC_CLASSIFIER_MODE:-allow}" DC_LOOP_GUARD="${DC_LOOP_GUARD:-on}" # key 不走 argv：`ps` 全機可見
        CHEAPCLAUDE_API_KEY="$RESOLVED_KEY" node "$SCRIPT_DIR/proxy/start-proxy.js" "$RESOLVED_URL" "" > "$port_file" 2>> "${DC_HOME:-$HOME/.deepclaude}/proxy.log" &
    PROXY_PID=$!
    local tries=0
    while [[ ! -s "$port_file" ]] && [[ $tries -lt 30 ]]; do
        sleep 0.2
        tries=$((tries + 1))
    done
    if [[ ! -s "$port_file" ]]; then
        echo "ERROR: Proxy failed to start" >&2
        rm -f "$port_file"
        exit 1
    fi
    proxy_port=$(head -1 "$port_file")
    rm -f "$port_file"
    echo "  Proxy on :$proxy_port -> $RESOLVED_URL"

    export ANTHROPIC_BASE_URL="http://127.0.0.1:$proxy_port"
    export ANTHROPIC_AUTH_TOKEN="$RESOLVED_KEY"
    set_model_env
    unset ANTHROPIC_API_KEY

    # NOT exec: exec replaces this shell and the EXIT trap never fires, leaking
    # one orphaned start-proxy.js per session. Plain call keeps the trap alive.
    # Headless box: nobody answers AskUserQuestion (81 calls blocked 25h total, avg 19min). Remove the tool.
    claude --disallowedTools AskUserQuestion "$@"
}

launch_remote() {
    if [[ "$BACKEND" == "anthropic" ]]; then
        echo "  Launching remote control (Anthropic)..."
        unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN
        unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL
        unset ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL
        unset CLAUDE_CODE_EFFORT_LEVEL ANTHROPIC_API_KEY
        exec claude remote-control "$@"
    fi

    resolve_backend

    echo "  Starting model proxy for $BACKEND..."

    local port_file
    port_file=$(mktemp "${TMPDIR:-/tmp}/deepclaude-port.XXXXXX")  # explicit template: macOS mktemp ignores TMPDIR otherwise
    DC_MODEL="$RESOLVED_OPUS" DC_SUBAGENT_MODEL="$RESOLVED_SUBAGENT_SPLIT" DC_SUBAGENT_MAX_OUTPUT="$RESOLVED_SUBAGENT_MAX_OUTPUT" DC_CLASSIFIER_MODE="${DC_CLASSIFIER_MODE:-allow}" DC_LOOP_GUARD="${DC_LOOP_GUARD:-on}" # key 不走 argv：`ps` 全機可見
        CHEAPCLAUDE_API_KEY="$RESOLVED_KEY" node "$SCRIPT_DIR/proxy/start-proxy.js" "$RESOLVED_URL" "" > "$port_file" 2>> "${DC_HOME:-$HOME/.deepclaude}/proxy.log" &
    PROXY_PID=$!

    local tries=0
    while [[ ! -s "$port_file" ]] && [[ $tries -lt 30 ]]; do
        sleep 0.2
        tries=$((tries + 1))
    done

    if [[ ! -s "$port_file" ]]; then
        echo "ERROR: Proxy failed to start" >&2
        rm -f "$port_file"
        exit 1
    fi

    local proxy_port
    proxy_port=$(head -1 "$port_file")
    rm -f "$port_file"

    echo "  Proxy on :$proxy_port -> $RESOLVED_URL"
    echo "  Launching remote control via $BACKEND..."
    echo ""

    export ANTHROPIC_BASE_URL="http://127.0.0.1:$proxy_port"
    set_model_env
    unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN

    claude remote-control "$@"
}

launch_happy() {
    resolve_backend

    local proxy_url="${DC_PROXY_URL:-http://127.0.0.1:20133}"
    if ! curl -s "$proxy_url/_proxy/status" >/dev/null 2>&1; then
        echo "ERROR: resident proxy not reachable at $proxy_url" >&2
        echo "  Start it: launchctl bootstrap gui/\$(id -u) ~/.deepclaude/launchd/local.deepclaude.proxy.plist" >&2
        exit 1
    fi

    export ANTHROPIC_BASE_URL="$proxy_url"
    export ANTHROPIC_AUTH_TOKEN="$RESOLVED_KEY"
    set_model_env

    # happy does not forward the parent's env — every var it needs must be
    # named explicitly via --claude-env.
    local args=(--yolo --disallowedTools AskUserQuestion)  # headless: see launch_claude
    local v val
    for v in ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN CLAUDE_CONFIG_DIR \
             ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \
             CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_MAX_OUTPUT_TOKENS CLAUDE_CODE_MAX_CONTEXT_TOKENS \
             CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT \
             CLAUDE_CODE_ATTRIBUTION_HEADER DISABLE_TELEMETRY DISABLE_ERROR_REPORTING \
             CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING ENABLE_TOOL_SEARCH; do
        val="${!v-}"
        [[ -n "$val" ]] && args+=(--claude-env "$v=$val")
    done

    exec happy "${args[@]}"
}

# --- Main ---
case "$ACTION" in
    status)    show_status ;;
    cost)      resolve_backend; show_cost ;;
    benchmark) run_benchmark ;;
    help)      show_help ;;
    switch)    do_switch ;;
    remote)    launch_remote "$@" ;;
    happy)     launch_happy ;;
    restart)   exec "${DC_HOME:-$HOME/.deepclaude}/bin/dc-restart" ;;
    launch)    launch_claude "$@" ;;
esac
