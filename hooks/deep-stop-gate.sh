#!/bin/bash
# deep-stop-gate.sh - Stop hook for deep-run headless sessions.
# Reads the Stop hook JSON from stdin. In an interactive session it passes through
# silently (exit 0, no output) so the machine a human is typing at is unaffected.
# For a deep-run session whose 驗收 still fails, it blocks the Stop up to
# DEEP_GATE_MAX_BLOCKS times (default 3, counter file per session), then lets it end.
# Every call appends a line to gate.log.
set -u

DC_HOME="${DC_HOME:-$HOME/.deepclaude}"
GATE_DIR="$DC_HOME/work/.deep/stop-gate"
mkdir -p "$GATE_DIR"
LOG="$GATE_DIR/gate.log"

# Read the Stop-hook JSON body from stdin; extract what we need with jq.
payload=$(cat)
stop_hook_active=$(printf '%s' "$payload" | jq -r '.stop_hook_active // false')
session_id=$(printf '%s' "$payload" | jq -r '.session_id // "unknown"')
SAFE_ID=$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9_-')
[ -n "$SAFE_ID" ] || SAFE_ID="unknown"
COUNT_FILE="$GATE_DIR/$SAFE_ID.blocks"
MAX_BLOCKS="${DEEP_GATE_MAX_BLOCKS:-3}"

# stop_hook_active=true means "continuing after a stop-hook block" (official docs), not
# "interactive". Only pass through when the block was someone else's, so our own
# retries up to MAX_BLOCKS still get re-verified.
if [ "$stop_hook_active" = "true" ] && [ ! -f "$COUNT_FILE" ]; then
    exit 0
fi

# The harness sometimes strips DEEP_TASK_FILE from the hook env (09-24 失聲, zero
# gate.log lines). Recover it from the by-cwd mirror: slug = cwd with / and . both
# replaced by -, same as deep-run's. If that also comes up empty, log the skip so the
# silence is at least visible, then pass through.
if [ -z "${DEEP_TASK_FILE:-}" ]; then
    cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""')
    if [ -n "$cwd" ]; then
        slug=$(printf '%s' "$cwd" | sed 's/[\/.]/-/g')
        recovered="$DC_HOME/work/.deep/by-cwd/$slug"
        if [ -f "$recovered" ]; then
            DEEP_TASK_FILE=$(cat "$recovered")
        fi
    fi
fi
if [ -z "${DEEP_TASK_FILE:-}" ]; then
    echo "$(date '+%F %T') $session_id skip:no-task-file" >> "$LOG"
    exit 0
fi

n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
if [ "$n" -ge "$MAX_BLOCKS" ]; then
    echo "$(date '+%F %T') $SAFE_ID skip:cap" >> "$LOG"
    exit 0
fi

wo-verify "$DEEP_TASK_FILE" >/tmp/deep-gate-verify.$$ 2>&1
vrc=$?
trap 'rm -f /tmp/deep-gate-verify.$$' EXIT
if [ "$vrc" = 0 ] || [ "$vrc" = 2 ]; then
    echo "$(date '+%F %T') $SAFE_ID pass" >> "$LOG"
    exit 0
fi

n=$((n + 1))
printf '%s' "$n" > "$COUNT_FILE"
reason="驗收未通過（wo-verify rc=${vrc}，第 ${n}/${MAX_BLOCKS} 次攔截）。原始輸出最後 30 行：$(tail -30 /tmp/deep-gate-verify.$$ | tr '\n' ' ')。修被驗物後再結束；禁改驗收指令、樣本、任務檔。"
jq -n --arg reason "$reason" '{decision:"block", reason:$reason}'
echo "$(date '+%F %T') $SAFE_ID block" >> "$LOG"
exit 0