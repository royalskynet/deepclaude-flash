#!/bin/bash
# deep-stop-gate.sh - Stop hook for deep-run headless sessions.
# Reads the Stop hook JSON from stdin. In an interactive session it passes through
# silently (exit 0, no output) so the machine a human is typing at is unaffected.
# For a deep-run session whose 驗收 still fails, it blocks the FIRST Stop — write the
# block decision to stdout so Claude Code records a block — and never blocks the
# same session again (marker file). Every call appends a line to gate.log.
set -u

DC_HOME="${DC_HOME:-$HOME/.deepclaude}"
GATE_DIR="$DC_HOME/work/.deep/stop-gate"
mkdir -p "$GATE_DIR"
LOG="$GATE_DIR/gate.log"

# Read the Stop-hook JSON body from stdin; extract what we need with jq.
payload=$(cat)
stop_hook_active=$(printf '%s' "$payload" | jq -r '.stop_hook_active // false')
session_id=$(printf '%s' "$payload" | jq -r '.session_id // "unknown"')

# Interactive session (no deployment gate) — nothing to enforce, no output, no log.
if [ "$stop_hook_active" = "true" ]; then
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

# One block per session: marker is keyed on the session_id, with everything outside
# [A-Za-z0-9_-] removed so it is a safe filename.
SAFE_ID=$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9_-')
[ -n "$SAFE_ID" ] || SAFE_ID="unknown"
MARKER="$GATE_DIR/$SAFE_ID.blocked"

if [ -f "$MARKER" ]; then
    echo "$(date '+%F %T') $SAFE_ID skip" >> "$LOG"
    exit 0
fi

wo-verify "$DEEP_TASK_FILE" >/tmp/deep-gate-verify.$$ 2>&1
vrc=$?
trap 'rm -f /tmp/deep-gate-verify.$$' EXIT
if [ "$vrc" = 0 ] || [ "$vrc" = 2 ]; then
    echo "$(date '+%F %T') $SAFE_ID pass" >> "$LOG"
    exit 0
fi

# 驗收 not passing yet — block this Stop, once per session.
touch "$MARKER"
reason="驗收未通過（wo-verify rc=${vrc}）。原始輸出最後 30 行：$(tail -30 /tmp/deep-gate-verify.$$ | tr '\n' ' ')。修被驗物後再結束；禁改驗收指令、樣本、任務檔。"
jq -n --arg reason "$reason" '{decision:"block", reason:$reason}'
echo "$(date '+%F %T') $SAFE_ID block" >> "$LOG"
exit 0