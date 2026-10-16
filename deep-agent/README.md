# deep-agent

> Source of truth: top-level `deep-agent/` in [royalskynet/deepclaude](https://github.com/royalskynet/deepclaude).
> royalskynet/deep-agent is a public mirror published by `repo/tools/sync-deep-agent-mirror.sh`.

The `deep` agent — the default subagent that runs a task
end-to-end, headless, outside the sandbox, via deepclaude.

`deep` means: hand the raw task text to the deepclaude-backed Claude Code loop and
let it run to completion with no supervision.

Entry points:

- **`/deep`**: slash command that forwards the task via Bash direct `deep-run`.
- **Bash direct**: `deep-run <task.md> [cwd]`.

Dependencies: [royalskynet/deepclaude](https://github.com/royalskynet/deepclaude),
and `gh` access (`GH_TOKEN` from `~/.creds/kv`, else `gh auth token`).

---

## Headless autonomous runs (deep-run)

Claude Code normally needs an interactive terminal or a remote-control session. For
long unattended coding jobs (migration, plumbing, doc generation), `deep-run` drives
the deepclaude-backed Claude Code loop headlessly: no TTY, no pausing, no "ask me
first" — it runs a single task end-to-end and prints a report.

**How to call it**:

```
deep-run <task.md> [cwd]
```

Behind the scenes it runs `claude -p` outside the sandbox with these flags:

```
--system-prompt-file config/deep-system.md
--tools Bash,Read,Edit,Write,Glob,Grep
--disable-slash-commands
--strict-mcp-config
--permission-mode bypassPermissions
--max-turns 150
```

No `--bare` on purpose: bare mode skips the `PreToolUse` hook, which would disarm the
`creds-egress-guard` that keeps credential values out of transcripts.

**The contract (`config/deep-system.md`)** — injected into the model as its system
prompt:

1. No supervision: never ask, never wait for confirmation.
2. Method in order: check past fixes → `gh search` repos/code/issues for a wheel
   (≤3 queries per problem) → smallest change → rerunnable verification → report in
   Traditional Chinese (what changed `path:line` / wheel URL or keywords / raw verify
   output / NOT DONE).
3. Irreversible or publish actions → stop and report.

**Task file format** — three sections, no step-by-step:

```
# 任務        (what to do)
# 驗收        (rerunnable acceptance command + expected output)
# 不動        (things never to touch)
```

Methodology lives in the system prompt, not the task file.

**Verification** — every run must end with a rerunnable command you can paste. See
`wrappers.log` for the call + `transcript` for the full trace. The log's `end` line
carries `verify=pass|fail|none` (the mechanical judge's verdict), and any real failure
is signalled via a nonzero `rc`: `TASK_TAMPERED` means the task file was changed while
the run was in progress, `CLAIM_MISMATCH` means the 驗收 block actually failed when
`wo-verify` re-ran it.

**Known limits:**
- Must be called via `deep-run` by its bare name — an absolute path won't match the
  sandbox's excluded-commands allowlist and silently drops back into the sandbox
  (node DNS dies instantly, faking a 502). `deep-run` detects the sandbox proxy env
  and exits 3.
- `≤3` search queries per problem keeps hiring fast but can feel slow on hard tasks
  (a smoke test took 40 `gh` calls, 6.5 min, 29 turns to pick one of 5 candidates).
- Interactive or vision-dependent tasks won't survive headless runs.

**Two-layer split + Stop gate (R3/R6)** — `deep-run` keeps only the launch half (PATH,
sandbox guard, GH_TOKEN, the read-only task snapshot, the `deep-run start` log line,
`DEEP_TASK_FILE`) and hands the actual model run to `deep-run-inner`, detached into a
private tmux socket: `tmux -L deep`. A `kill -9` on the foreground `deep-run` no longer
kills the job — the tmux session survives and finishes, writing its stdout to
`$DC_HOME/work/.deep/<epoch>.out` and its final rc to `.deep/<epoch>.rc`, which the
(re-attached) `deep-run` replays. Set `DEEP_NO_TMUX=1` to run the inner directly
(testing / debugging). A Stop hook (`deep-stop-gate.sh`) blocks — once, per session,
marker file `work/.deep/stop-gate/<session_id>.blocked` — any Stop issued while the
task's read-only copy still fails `wo-verify`, printing `{"decision":"block",…}` and
logging pass/block/skip to `work/.deep/stop-gate/gate.log`. Interactive sessions
(zero `DEEP_TASK_FILE`, or `stop_hook_active:true`) pass through silently.

**兩層結構＋Stop 閘門（R3/R6）**：`deep-run` 只留 launch 半（PATH、沙箱偵測、GH_TOKEN、
唯讀任務快照、`deep-run start` 日誌行、`DEEP_TASK_FILE`），把真正跑模型的
`deep-run-inner` 用私有 tmux socket（`tmux -L deep`）detach 出去。前景 `deep-run`
被 `kill -9` 不再殺掉工作——tmux session 存活跑完，stdout 寫到
`$DC_HOME/work/.deep/<epoch>.out`、最終 rc 寫到 `.deep/<epoch>.rc`，`deep-run`（重新
接上）再回放。設 `DEEP_NO_TMUX=1` 可直接跑 inner（測試／除錯）。Stop hook
（`deep-stop-gate.sh`）在任務唯讀副本仍過不了 `wo-verify` 時，每 session 只擋一次
（marker 檔 `work/.deep/stop-gate/<session_id>.blocked`），印
`{"decision":"block",…}`，並把 pass/block/skip 記到 `work/.deep/stop-gate/gate.log`。
互動 session（`DEEP_TASK_FILE` 為空，或 `stop_hook_active:true`）零影響直接放行。

### 中文說明

Claude Code 平常需要互動終端或遠端控制連線。要跑長時間無人看守的程式任務（搬檔、
接線、生文件）時，`deep-run` 以無頭方式驅動 deepclaude 背後的 Claude Code 迴圈：
不開 TTY、不停頓、不「先問再動」——單一任務一路做到完，輸出報告。

**呼叫方式**：

```
deep-run <task.md> [cwd]
```

內部在沙箱外執行 `claude -p`，旗標如下：

```
--system-prompt-file config/deep-system.md
--tools Bash,Read,Edit,Write,Glob,Grep
--disable-slash-commands
--strict-mcp-config
--permission-mode bypassPermissions
--max-turns 150
```

刻意不用 `--bare`：bare 模式會跳過 `PreToolUse` hook，等於廢掉 `creds-egress-guard`
（保護憑證值不外洩 transcript）。

**契約（`config/deep-system.md`）**——注入模型當 system prompt：

1. 無人看守：不准問、不准等確認。
2. 方法依序：查舊帳 → `gh search` repos/code/issues 找輪子（每題 ≤3 query）→ 最小
   改動 → 可重跑驗證 → 繁中回報（改了啥 `path:line`／輪子 URL 或查過的關鍵字／驗證
   原始輸出／NOT DONE）。
3. 不可逆或對外發布 → 停下回報。

**任務檔格式**——三段，不寫步驟：

```
# 任務        （要做什麼）
# 驗收        （可重跑的驗收指令＋預期輸出）
# 不動        （絕不碰的東西）
```

工單若描述 API 請求形狀（URL 含 `vN`、`POST /`、`請求形狀`、`wire shape`）必須附探針
證據：`探針：http=<code> …` 行（`api-probe <url> <keyfile>` 實打拿到的 4xx 錯誤體，
fix 9356）；deep-lint 會 warn 缺證據的形狀描寫——zod 錯誤體才是真 schema。deep-lint
閘門完整清單看 `deep-lint` 檔內註解與 `test-deep-lint.sh` fixtures。

方法論在 system prompt，不在任務檔。

**驗證**——每次 run 結尾必須有可重跑的指令。呼叫細節看 `wrappers.log`，完整軌跡
看 `transcript`。

**已知限制：**
- 必須用 `deep-run` 的 bare 名稱呼叫——絕對路徑不符合沙箱 excluded-commands 白名單，
  會無聲掉回沙箱（node DNS 秒死、偽裝成 502）。`deep-run` 偵測到沙箱 proxy env 即
  exit 3。
- 每題 ≤3 query 維持招聘速度，但硬任務會偏慢（煙測一次比 5 個候選用了 40 次 gh、
  6.5 分鐘、29 turns）。
- 需要互動或 vision 的任務活不過無頭執行。

## Efficiency harness

`deep` is a main loop with no `Agent` tool, so it never spawns subagents — anything
aimed at subagent traffic never reaches it. `deep-run` therefore configures the
deepclaude proxy directly:

| Env var | Set by `deep-run` | What it does |
|---|---|---|
| `CHEAPERINFERENCE_MODEL` | `deepseek-v4-flash-0731` | Pins the cheap model. The interactive launcher may default to a Pro-class model; deep does not need it and it costs ~10x on this workload. |
| `DC_MAIN_HARNESS_FILE` | `$DC_HOME/repo/proxy/subagent-harness.md` | Prepends the ponytail lazy-senior-dev ruleset ([MIT](https://github.com/DietrichGebert/ponytail)) to the main loop's system prompt. |
| `DC_LOOP_GUARD` | `on` | Watches the conversation and appends a short system message when the loop degenerates. |

The loop guard is stateless — it reads the request body, so a restarted proxy or a
resumed conversation still measures correctly. Three nudges, tunable by env:

- `DC_GUARD_SINGLES` (4) — consecutive turns worth **one shell command**. Not one
  `tool_use` block: a Bash call that chains commands with `;`, `&&`, `||` or newlines
  is already batched, and quoted or heredoc separators do not count. Each turn
  resends the whole context, so a run of genuinely-one-thing turns is the main waste.
- `DC_GUARD_NARRATION` (3000) — characters of prose written so far. Fires once per
  **doubling** of that budget (3k, 6k, 12k, …), so a very chatty run gets ~6 nudges
  rather than one on every remaining turn.
- `DC_GUARD_ROUNDS` (15) — turn count; every multiple demands converge-or-stop, and
  from the third one on it stops offering the choice. Repeating an identical demand is
  what an ignored nudge looks like: 8/78 corpus sessions cross the threshold four or
  more times and one crosses it seventeen times.

Why these numbers: measured over 77 real `deep-run` sessions / 1,780 tool rounds.

| Metric | Value |
|---|---|
| Rounds with exactly one `tool_use` block | 88.8% |
| Rounds with exactly one *shell command* | **35.8%** (4.27 commands per round) |
| Trailing run of genuine one-command rounds | p50 1, p90 4, max 32 |
| Mid-run narration, excluding the final report | p50 252 chars, p90 31k, max 138k |
| Rounds per session | p50 3, p90 67, max 252; 25/77 reach 15 |
| *Repeated* commands | 0.2% |

The block count overstates the problem 2.5x — deep batches far more than it first
appeared, and the earlier threshold of 3 one-block turns would have nudged 62% of
runs, most of them already batched. Counting shell commands instead puts the
threshold where the behaviour actually becomes abnormal. The waste that remains is
turn count and prose, not retries. A static prompt rule did not move it (the config
already asked for batching), which is why the guard injects at the moment of the
behaviour instead.

Measured effect of the 2026-09-15 metric correction, replaying both versions of the
guard over 118 tool rounds from 16 fresh `deep-run` audits: 29 nudges before, 7 after
(25% of rounds carried one, now 6%), with the batching nudge dropping from 18 firings
to 1. Output quality was unchanged — both A/B arms produced their report in 8/8 runs
at 98-99% recall. The guard's *positive* effect is still unmeasured: at these
thresholds it fired 3 times across those 16 runs, so a normal-workload A/B cannot see
it. See DEVLOG for the full table.

Self-checks (stdlib only, no network):

- `node <deepclaude>/repo/proxy/test-loop-guard.mjs` — the guard's counting and nudges.
- `bin/test-deep-run.sh` — how `deep-run` composes the Claude Code invocation: the cwd
  is stated, no `--bare`, no `Agent` tool, the cheap model and harness are pinned, and
  an absolute-path call refuses to run inside the sandbox.

## Publishing

This directory is the only part of the private deepclaude repo that becomes public,
so it is published by `repo/tools/sync-deep-agent-mirror.sh` rather than by
`git subtree push`. The script exports what git *tracks* (never the working tree),
runs a leak gate over the export — absolute home paths, transcript slugs, internal
fix-log ids, launchd uid targets, credential shapes, e-mail addresses — and pushes
only if the gate passes. `--dry-run` shows the diff without committing.

### 效率 harness（繁體中文）

`deep` 是沒有 `Agent` 工具的主 loop，永遠不會產生 subagent —— 所以任何針對 subagent
流量的東西都碰不到它。`deep-run` 因此直接設定 deepclaude proxy：

| 環境變數 | `deep-run` 設的值 | 作用 |
|---|---|---|
| `CHEAPERINFERENCE_MODEL` | `deepseek-v4-flash-0731` | 釘住便宜模型。互動式 launcher 可能預設 Pro 級模型，deep 不需要，且在這種用量下貴約 10 倍。 |
| `DC_MAIN_HARNESS_FILE` | `$DC_HOME/repo/proxy/subagent-harness.md` | 把 ponytail 懶惰資深開發者 ruleset（[MIT](https://github.com/DietrichGebert/ponytail)）前置到主 loop 的 system prompt。 |
| `DC_LOOP_GUARD` | `on` | 監看對話，迴圈退化時附加一句 system 訊息。 |

loop guard 無狀態——直接讀請求內容，所以 proxy 重啟或對話續跑都算得準。三條 nudge，
都可用環境變數調：

- `DC_GUARD_SINGLES`（4）——連續幾輪「只做一件事」。算的是 **shell 指令數**不是
  `tool_use` 數：同一個 Bash call 用 `;`、`&&`、`||` 或換行串起來就算批次過了，
  引號內與 heredoc 內的分隔符不計。每輪都要重送整包 context，真正的單發連續輪是
  主要浪費來源。
- `DC_GUARD_NARRATION`（3000）——已寫的敘述字數。每**翻倍**觸發一次（3k、6k、12k…），
  所以話很多的 run 大約收到 6 次，而不是超過門檻後每輪都收到。
- `DC_GUARD_ROUNDS`（15）——輪數；每到倍數就要求收斂或停手，第三次開始不再給選項。
  重複同一句話正是 nudge 被無視的樣子：語料裡 8/78 個 session 會跨過門檻四次以上，
  其中一個跨了十七次。

為什麼是這些數字：實測 77 個真實 `deep-run` session、1,780 個工具輪。

| 指標 | 數值 |
|---|---|
| 剛好一個 `tool_use` block 的輪次 | 88.8% |
| 剛好一條 *shell 指令* 的輪次 | **35.8%**（平均 4.27 條／輪） |
| 真正單指令輪的連續長度 | p50 1、p90 4、最長 32 |
| 跑動中敘述字數（不含最後報告） | p50 252 字、p90 3.1 萬、最長 13.8 萬 |
| 每 session 輪數 | p50 3、p90 67、最長 252；77 個裡 25 個達到 15 |
| **重複**指令 | 0.2% |

用 block 數算會高估問題 2.5 倍——deep 其實批次得比表面看起來多，而舊的「連續 3 個
單 block 輪」門檻會對 62% 的連續段開罵，其中多數早就批次過了。改算 shell 指令數，
門檻才落在行為真正變不正常的位置。剩下的浪費在輪數與廢話，不在重試。靜態 prompt
規則沒有用（設定檔早就要求批次了），所以 guard 改成在行為發生的當下注入。

自檢（純 stdlib，不連網）：

- `node <deepclaude>/repo/proxy/test-loop-guard.mjs`——guard 的計數與 nudge。
- `bin/test-deep-run.sh`——`deep-run` 怎麼組出 Claude Code 的呼叫：有沒有講清楚工作目錄、
  沒有 `--bare`、沒有 `Agent` 工具、便宜模型與 harness 有釘住、用絕對路徑呼叫會拒跑。

### 發佈（繁體中文）

這個目錄是私有 deepclaude repo 裡唯一會變公開的部分，所以用
`repo/tools/sync-deep-agent-mirror.sh` 發佈，不用 `git subtree push`。腳本匯出的是 git
**追蹤**的內容（絕不是工作目錄），對匯出結果跑一道洩漏閘門——絕對家目錄路徑、transcript
slug、內部 fix log 編號、launchd uid target、憑證樣式、email——通過才推。`--dry-run`
只顯示差異不提交。

## Bench

量 deep 是否飄移用的固定回歸：`bench/run.sh <a|b|c> <n>` 對三張固定任務做 n 輪
（a＝補執行權限、b＝驗收自相矛盾、c＝SSOT 與驗收衝突）。每輪起 `bench/fixture.sh` 建
fixture、`deep-run` 跑任務，判 pass/fail，回合細節寫進 `bench/results/<date>-<x>.log`
（結果目錄已 gitignore），結尾印一行 `pass=<k>/<n>`。

## Install

```
~/.deepclaude/deep-agent/install.sh
```

Symlinks the repo into place (deepclaude's agent / skill / command, plus
`~/.local/bin/deep-run`). Requires deepclaude
([royalskynet/deepclaude](https://github.com/royalskynet/deepclaude)) and
`gh` access (`GH_TOKEN` in `~/.creds/kv`, else a `gh auth login`). Rerunnable; must be sourced from the current repo
checkout.