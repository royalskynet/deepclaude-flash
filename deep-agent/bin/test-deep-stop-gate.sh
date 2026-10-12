#!/usr/bin/env bash
# Self-check for deep-stop-gate.sh's env-scrub recovery (09-24 失聲). No network, no
# model: builds a fake DC_HOME, a task whose 驗收 must fail, mirrors it in by-cwd, then
# feeds the hook a Stop payload WITHOUT DEEP_TASK_FILE in env. Expect: a block decision
# when the cwd matches, and a skip:no-task-file log line when it does not.
# Run: deep-agent/bin/test-deep-stop-gate.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DC_HOME=$(mktemp -d "${TMPDIR:-/tmp}/deep-sg-test.XXXXXX")
trap 'rm -rf "$DC_HOME"' EXIT
GATE_DIR="$DC_HOME/work/.deep/stop-gate"
mkdir -p "$GATE_DIR"
LOG="$GATE_DIR/gate.log"
BYCWD="$DC_HOME/work/.deep/by-cwd"
mkdir -p "$BYCWD"
rc=0

# A task whose 驗收 must fail under wo-verify (set -e, grep -q against nothing).
task="$DC_HOME/work/bad-task.md"
cat > "$task" <<'EOF'
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
grep -q DEFINITELY_NOT_PRESENT /etc/hosts
```
預期：rc=0。
## 禁止
- 禁止改 fixture。
EOF

# Mirror it under by-cwd with slug = cwd, / and . both -> -.
cwd="$DC_HOME/work/cwd/子目錄"
mkdir -p "$cwd"
slug=$(printf '%s' "$cwd" | sed 's/[\/.]/-/g')
printf '%s' "$task" > "$BYCWD/$slug"

# Need wo-verify on PATH (vendored in same bin dir).
export PATH="$HERE:$PATH"

# Case 1: matching cwd -> hook must recover the task file and block.
out=$(printf '{"session_id":"t1","cwd":"%s","stop_hook_active":false}' "$cwd" \
  | env -u DEEP_TASK_FILE "$HERE/../hooks/deep-stop-gate.sh" 2>&1)
case "$out" in
  *'"decision": "block"'*|*block*) echo "ok: by-cwd 命中→block" ;;
  *) echo "FAIL: by-cwd 命中未 block — $out"; rc=1 ;;
esac

# Case 2: unknown cwd -> no task file -> skip:no-task-file logged, no output.
out2=$(printf '{"session_id":"t2","cwd":"%s/nope","stop_hook_active":false}' "$cwd" \
  | env -u DEEP_TASK_FILE "$HERE/../hooks/deep-stop-gate.sh" 2>&1)
if tail -1 "$LOG" | grep -q 'skip:no-task-file'; then
  echo "ok: 無 by-cwd 對應→skip:no-task-file 落 log"
else
  echo "FAIL: 無 by-cwd 對應未記 skip:no-task-file — log尾: $(tail -1 "$LOG")"; rc=1
fi

exit "$rc"
