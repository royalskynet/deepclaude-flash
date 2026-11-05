#!/usr/bin/env bash
# Self-check for how deep-run composes the Claude Code invocation. No network: a stub
# `deepclaude` earlier on PATH records argv and environment instead of running one.
# Run: bin/test-deep-run.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/deep-run-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
# deep-run prepends $HOME/.local/bin to PATH, so that is where the stub has to live
# for it to win — pointing PATH at a scratch dir is not enough.
mkdir -p "$tmp/home/.local/bin" "$tmp/work" "$tmp/home/.deepclaude/config" "$tmp/home/.creds/kv"
# Pin DC_HOME into the scratch HOME. deep-run defaults it to $HOME/.deepclaude, so a
# stray DC_HOME in the caller's env (e.g. on the m1 dev box) would otherwise redirect
# the snapshot into the real runtime copy and silently break every assertion below.
export DC_HOME="$tmp/home/.deepclaude"
touch "$tmp/home/.deepclaude/config/deep-system.md"
printf -- '---\nid: WO-0\n---\ntask\n' > "$tmp/task.md"

cat > "$tmp/home/.local/bin/deepclaude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_ARGV"
env | grep -E '^(OPENCODE_GO_MODEL|DC_MAIN_HARNESS_FILE|DC_LOOP_GUARD|GH_TOKEN|DEEP_TASK_FILE)=' | sort > "$STUB_ENV"
STUB
chmod +x "$tmp/home/.local/bin/deepclaude"
# No kv token in the fake creds dir, so deep-run must take GH_TOKEN from `gh auth token`.
printf '#!/usr/bin/env bash\necho stub-gh-token\n' > "$tmp/home/.local/bin/gh"
chmod +x "$tmp/home/.local/bin/gh"

HOME="$tmp/home" CREDS_DIR="$tmp/home/.creds" \
  STUB_ARGV="$tmp/argv" STUB_ENV="$tmp/env" WLOG="$tmp/w.log" HTTPS_PROXY="" GH_TOKEN="" \
  DEEP_NO_TMUX=1 "$HERE/deep-run" "$tmp/task.md" "$tmp/work" >/dev/null 2>&1

argv=$(cat "$tmp/argv" 2>/dev/null) || { echo "FAIL: stub never ran"; exit 1; }
envs=$(cat "$tmp/env" 2>/dev/null)
fail=0
check() { if eval "$2"; then :; else echo "FAIL: $1"; fail=1; fi; }

# The working directory has to be stated: --system-prompt-file replaces Claude Code's
# default prompt, taking the environment block that names the cwd with it. Without
# this, deep searches the filesystem for its own task files.
check "--append-system-prompt names the cwd"      'grep -qF -- "$tmp/work" <<< "$argv" && grep -qx -- "--append-system-prompt" <<< "$argv"'
check "--system-prompt-file still passed"          'grep -qx -- "--system-prompt-file" <<< "$argv"'
# --bare skips hooks, which disarms the credential-egress guard. Measured, not assumed.
check "no --bare"                                  '! grep -qx -- "--bare" <<< "$argv"'
# deep has no Agent tool, which is why it needs the MAIN harness rather than the
# subagent one; if Agent ever appears here, that reasoning no longer holds.
check "no Agent tool"                              '! grep -q "Agent" <<< "$argv"'
check "--permission-mode bypassPermissions"        'grep -qx -- "bypassPermissions" <<< "$argv"'
check "--max-turns set"                            'grep -qx -- "--max-turns" <<< "$argv"'
check "pins the cheap model"                       'grep -q "^OPENCODE_GO_MODEL=deepseek-v4.1-flash" <<< "$envs"'
check "points the proxy at the main harness"       'grep -q "^DC_MAIN_HARNESS_FILE=.*deep-harness.md$" <<< "$envs"'
check "loop guard on by default"                   'grep -qx "DC_LOOP_GUARD=on" <<< "$envs"'
# Without a token deep cannot `gh search` for an existing wheel, so a machine with no
# kv mirror must still get one from the gh login.
check "GH_TOKEN falls back to gh auth token"      'grep -qx "GH_TOKEN=stub-gh-token" <<< "$envs"'

# (a) The -p arg deepclaude receives is the read-only snapshot deep-run copied into
# $DC_HOME/work/.deep/{epoch}-task.md (chmod 444), never the caller's live file. Each
# run mints a fresh epoch, so the copy must be globbed.
p_body="$(awk '$0=="-p"{on=1;next} on&&$0=="--output-format"{on=0} on{print}' "$tmp/argv")"
snapshot="$(cat "$tmp/home/.deepclaude/work/.deep/"*-task.md)"
# 工單以 `---` frontmatter 開頭：-p 的值若以 `-` 起頭，真 CLI 會報 unknown option（WO-12 10-19）。
check "(-p) value never starts with -"             '[ -n "$p_body" ] && [ "${p_body:0:1}" != "-" ]'
check "(-p) body is the read-only work/.deep snapshot" \
  '[ "$p_body" = "Task file:"$'"'"'\n'"'"'"$snapshot" ] && ls -l "$tmp/home/.deepclaude/work/.deep/"*-task.md | grep -qF -- "-r--r--r--"'
# (b) The snapshot path also goes to deep via DEEP_TASK_FILE, so deep knows the file
# the caller-and-judge keep consistent.
dtf_env="$(grep '^DEEP_TASK_FILE=' "$tmp/env" | cut -d= -f2-)"
check "DEEP_TASK_FILE set and points at the snapshot" \
  '[ -n "$dtf_env" ] && [ -f "$dtf_env" ] && [ "$dtf_env" = "$(ls "$tmp/home/.deepclaude/work/.deep/"*-task.md)" ]'
# (c) The main loop carries the ponytail ruleset via deep-harness.md, not the
# subagent one (deep has no Agent tool, so the subagent harness never fires).
check "harness name ends with deep-harness.md"     'grep -q "^DC_MAIN_HARNESS_FILE=.*deep-harness.md$" <<< "$envs"'

# An absolute path bypasses the sandbox allowlist entry ("deep-run *"), so deep-run
# must refuse rather than silently run inside the sandbox with DNS dead.
out=$(HOME="$tmp/home" WLOG="$tmp/w.log" HTTPS_PROXY="http://localhost:8080" \
      "$HERE/deep-run" "$tmp/task.md" "$tmp/work" 2>&1); rc=$?
check "refuses to run inside the sandbox"          '[ "$rc" = 3 ] && grep -q "INSIDE sandbox" <<< "$out"'

# (d) End-to-end with the real mechanical judge (wo-verify, not the stub): a task
# whose 驗收 block fails must make deep-run exit nonzero and print CLAIM_MISMATCH.
cat > "$tmp/fail.md" <<'BAD'
# 任務
fail this on purpose

## 驗收
```sh
false
```

預期： 會失敗，rc≠0
BAD
fout=$(HOME="$tmp/home" CREDS_DIR="$tmp/home/.creds" WLOG="$tmp/w2.log" HTTPS_PROXY="" \
       STUB_ARGV="$tmp/argv2" STUB_ENV="$tmp/env2" DEEP_NO_TMUX=1 \
       "$HERE/deep-run" "$tmp/fail.md" "$tmp/work" 2>&1); frc=$?
check "failing 驗收 block ⇒ CLAIM_MISMATCH, rc≠0" \
  '[ "$frc" != 0 ] && grep -q "CLAIM_MISMATCH" <<< "$fout"'

# Guard (wo-verify absent): 工具缺席不得渲染成任務失敗。移開同目錄 vendor 版、PATH 剝掉
# wo-verify 後收尾檢查必須 rc=0、不印 CLAIM_MISMATCH、印明確降級訊息。
(
  trap 'mv "$tmp/wo-verify.hidden" "$HERE/wo-verify"' EXIT
  mv "$HERE/wo-verify" "$tmp/wo-verify.hidden"
  PATH="$tmp/home/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  gout=$(HOME="$tmp/home" CREDS_DIR="$tmp/home/.creds" WLOG="$tmp/wg.log" HTTPS_PROXY="" \
         STUB_ARGV="$tmp/argvg" STUB_ENV="$tmp/envg" DEEP_NO_TMUX=1 \
         "$HERE/deep-run" "$tmp/task.md" "$tmp/work" 2>&1); grc=$?
  check "wo-verify absent ⇒ no CLAIM_MISMATCH, rc=0, degrade msg" \
    '[ "$grc" = 0 ] && ! grep -q "CLAIM_MISMATCH" <<< "$gout" && grep -q "not machine-checked" <<< "$gout"'
)
[ -x "$HERE/wo-verify" ] || { echo "FAIL: wo-verify not restored"; fail=1; }

# R6 (a): default mode must detach the model run into a private tmux session. A fake
# `tmux` (earlier on PATH than the real one, since deep-run prepends ~/.local/bin)
# records argv instead of actually creating a session. DEEP_NO_TMUX is unset.
cat > "$tmp/home/.local/bin/tmux" <<'TMSTUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$TMUX_ARGV"
TMSTUB
chmod +x "$tmp/home/.local/bin/tmux"
TMUX_ARGV="$tmp/tmux.argv" GTMP="$(mktemp -d "${TMPDIR:-/tmp}/deep-tmux.XXXXXX")" \
  HOME="$tmp/home" CREDS_DIR="$tmp/home/.creds" WLOG="$tmp/wt.log" HTTPS_PROXY="" GH_TOKEN="" \
  "$HERE/deep-run" "$tmp/task.md" "$tmp/work" >/dev/null 2>&1
tmux_args="$(cat "$tmp/tmux.argv" 2>/dev/null)"
check "tmux detach uses private -L deep socket + new-session" \
  'grep -q -- "-L" <<< "$tmux_args" && grep -q -- "deep" <<< "$tmux_args" && grep -q "new-session" <<< "$tmux_args"'

# R3 (b): the Stop gate blocks a live deep-run session whose 驗收 still fails up to
# DEEP_GATE_MAX_BLOCKS times per session, then is silent.
GATE="$HERE/../hooks/deep-stop-gate.sh"
g1=$(echo '{"session_id":"t1","stop_hook_active":false}' | DEEP_GATE_MAX_BLOCKS=2 DEEP_TASK_FILE="$tmp/fail.md" DC_HOME="$tmp/home/.deepclaude" \
      "$GATE" 2>&1)
g2=$(echo '{"session_id":"t1","stop_hook_active":true}' | DEEP_GATE_MAX_BLOCKS=2 DEEP_TASK_FILE="$tmp/fail.md" DC_HOME="$tmp/home/.deepclaude" \
      "$GATE" 2>&1)
g3=$(echo '{"session_id":"t1","stop_hook_active":true}' | DEEP_GATE_MAX_BLOCKS=2 DEEP_TASK_FILE="$tmp/fail.md" DC_HOME="$tmp/home/.deepclaude" \
      "$GATE" 2>&1)
check "Stop gate blocks failing 驗收 up to cap, then silent" \
  '[ -n "$(grep -E "\"decision\": *\"block\"" <<< "$g1")" ] && [ -n "$(grep -E "\"decision\": *\"block\"" <<< "$g2")" ] && [ -z "$g3" ]'

# R9: cwd 帶 .git/deep-live 標記（現役服務 working tree）→ exit 4、不跑模型、提示 worktree；
# 同 repo 的 worktree（.git 是檔案）照常放行。
live="$tmp/live"; git init -q "$live" && git -C "$live" commit -q --allow-empty -m init && touch "$live/.git/deep-live"
rm -f "$tmp/argvl"
lout=$(HOME="$tmp/home" CREDS_DIR="$tmp/home/.creds" WLOG="$tmp/wl.log" HTTPS_PROXY="" STUB_ARGV="$tmp/argvl" STUB_ENV="$tmp/envl" \
  DEEP_NO_TMUX=1 "$HERE/deep-run" "$tmp/task.md" "$live" 2>&1); lrc=$?
check "live working tree ⇒ exit 4, model not run, worktree hint" \
  '[ "$lrc" = 4 ] && [ ! -e "$tmp/argvl" ] && grep -q "worktree add" <<< "$lout"'
git -C "$live" worktree add -q "$tmp/livewt" -b wt 2>/dev/null
HOME="$tmp/home" CREDS_DIR="$tmp/home/.creds" WLOG="$tmp/wl2.log" HTTPS_PROXY="" STUB_ARGV="$tmp/argvw" STUB_ENV="$tmp/envw" \
  DEEP_NO_TMUX=1 "$HERE/deep-run" "$tmp/task.md" "$tmp/livewt" >/dev/null 2>&1
check "worktree of a live repo is allowed" '[ -s "$tmp/argvw" ]'

[ "$fail" = 0 ] && echo "OK: 20/20 deep-run invocation checks passed"
exit "$fail"
