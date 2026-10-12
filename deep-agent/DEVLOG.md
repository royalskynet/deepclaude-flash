# 2026-09-29 (prompt cache 恢復：proxy 摺疊後段 system 訊息)

deep-run 的每輪請求都經過 deepclaude proxy。Claude Code 每輪會在對話尾端追加一條
`role:system` 的 `<total_tokens>N tokens left</total_tokens>`（N 每輪不同），loop guard 的
nudge 也走同一條管道。CheaperInference 會把所有 system 訊息提升到頂端 system prompt，
導致 prompt 開頭每輪改變，快取只命中開頭那一小段。proxy 現在把第一個 assistant 之後的
system 訊息改成 `<system-reminder>` 文字，併進相鄰的 user 訊息（規則同 adatoo/quail#99；
上游 bug 為 anthropics/claude-code#90018）。實測 deep-run 8 輪：第 3 輪起 cacheR 隨前綴
增長，命中 92–97%。loop guard 的 nudge 現在以 user 訊息最後一個 block 的形式送出，
assistant 歷史仍然不動。

Every deep-run request goes through the deepclaude proxy. Claude Code appends a
`role:system` `<total_tokens>N tokens left</total_tokens>` message each turn (N changes),
and the loop guard's nudges use the same channel. CheaperInference hoists every system
message into the top system prompt, so the prompt head changed every turn and only a
small leading slice ever hit the cache. The proxy now folds system messages that come
after the first assistant turn into `<system-reminder>` text on the adjacent user turn
(same rule as adatoo/quail#99; upstream bug anthropics/claude-code#90018). Measured on an
8-turn deep-run: from turn 3 on, cacheR grows with the prefix at 92–97% hit. Loop-guard
nudges now arrive as the last block of the last user turn; assistant history is still
never touched.

# 2026-09-16 (R3 Stop gate + R6 tmux detach)

新增 `bench/`：`fixture.sh`／`run.sh`＋三張固定回歸任務（a 補權限、b 驗收矛盾、c SSOT 與
驗收衝突），`run.sh <a|b|c> <n>` 跑 n 輪判 pass/fail、寫 `bench/results/<date>-<x>.log`，量
deep 是否飄移。

Bench 首輪（主 session 跑，任務檔「預期」行已改中性，不告訴 deep 是陷阱）：
a 5/5、b 4/5、c 5/5。b 失敗的一輪 deep 判斷正確（NOT DONE＋驗收矛盾）但先拿樣本
README.md 做了三次內容實驗再寫回，`git status --porcelain` 不空 → 判 fail；
下一步是把「探測也不可寫被驗物」寫成 deep-system 動詞級規則。主 session 另補三修：
GH_TOKEN 不再走 tmux 命令列（inner 自取）、R2 hash 改在模型跑前算並同時比對副本、
gate 暫存檔 trap 清理；settings.json 的 Stop entry 去重成一筆。

First bench (run from the main session, with neutral 預期 lines so the task file does not
tell deep it is a trap): a 5/5, b 4/5, c 5/5. The one failing b round reached the right
verdict (NOT DONE, contradictory acceptance) but first experimented on the sample README.md
three times and wrote it back, leaving `git status --porcelain` non-empty. Follow-up: a
verb-level deep-system rule that probing must not write the verified file either. Main-session
fixes on top: GH_TOKEN no longer rides the tmux command line (inner resolves it), the R2 hash
is taken before the model runs and the copy is compared too, the gate cleans its temp file
via trap; settings.json now carries a single Stop gate entry.

`deep-run` 拆成兩層：前置留在 `deep-run`，真正的 deepclaude 主迴圈（含 hash 比對、
wo-verify、wrappers.log end 行、transcript 統計）搬進 `deep-run-inner`，用私有
`tmux -L deep` socket detach（`DEEP_NO_TMUX=1` 直接跑，測試用）；前景 `deep-run`
`wait-for` 後回放 `.deep/<epoch>.out` 並以 `.rc` 結束。實測：前景 `deep-run` 被
`kill -9` 後 tmux 內工作照跑完，end 行 `rc=0 verify=pass`。`deep-run` 經
`~/.local/bin` symlink 呼叫時 `$0` 會解錯 inner 路徑（指向不存在的
`~/.local/bin/deep-run-inner`），已用 `readlink` 解 symlink 修正。新增 Stop gate
`deep-stop-gate.sh`（install 註冊成 symlink）：DEEP_TASK_FILE 非空且該 session 未擋過
時跑 `wo-verify`，rc≠0/2 印 `{"decision":"block"}`、touch marker、記 gate.log
（bash 3.2 對「變數緊鄰全形括號」解析會吞變數名，`$vrc`→`${vrc}` 修正）。17/17
（原 15 檢改 DEEP_NO_TMUX=1，新增 tmux `-L deep`/`new-session` argv 檢＋gate 擋一次
檢）。註冊與啟用靠 `config/settings.json`（未 commit）的 `hooks.Stop` 新 entry。

`deep-run` now splits into two layers: the launch half stays in `deep-run`; the real
deepclaude main loop (hash compare, wo-verify, wrappers.log end line, transcript stats)
moves into `deep-run-inner`, detached on a private `tmux -L deep` socket (`DEEP_NO_TMUX=1`
runs it inline for tests); the foreground `deep-run` waits, then replays `.deep/<epoch>.out`
and exits with `.rc`. Verified: killing the foreground `deep-run` with `kill -9` leaves the
tmux job running to completion (`end rc=0 verify=pass`). Fixed `$0` symlink resolution so
`deep-run` reached via `~/.local/bin` finds the real inner (it used to point at a
nonexistent `~/.local/bin/deep-run-inner`). New Stop gate `deep-stop-gate.sh` (registered
as a symlink in install): with `DEEP_TASK_FILE` set and this session not yet blocked, it
runs `wo-verify`; rc∉{0,2} prints `{"decision":"block"}`, touches a marker, and logs to
gate.log. Fixed a bash 3.2 parse bug where a variable directly before a full-width paren
swallowed part of the name (`$vrc`→`${vrc}`). 17/17 (the 15 original checks now run with
`DEEP_NO_TMUX=1`; two new checks: tmux `-L deep`/`new-session` argv, and the gate blocking
once then staying silent). Registration lives in `config/settings.json` (not committed)
as a new `hooks.Stop` entry.

# 2026-09-16

`deep-run` copies the caller's task file read-only into `$DC_HOME/work/.deep/{epoch}-task.md`
(chmod 444) and hands deepclaude the copy via `-p` plus `DEEP_TASK_FILE`, so a live edit
of the caller's own file never reaches the model; `test-deep-run.sh` now checks the
snapshot content, its perms, and the env pointer (15/15, up from 11/11). The proxy harness
default moved to `deep-harness.md`, and a failing 驗收 block now prints `CLAIM_MISMATCH`
and exits nonzero (verified end-to-end through the real `wo-verify`). New `deep-lint`
gates a task file's contract before dispatch — one-sentence task + one runnable read-only
驗收 block + an out-of-block `預期：` line, ≤40 lines, no drift log.

`deep-run` 把呼叫方的任務檔唯讀複製進 `$DC_HOME/work/.deep/{epoch}-task.md`（chmod 444），
並經 `-p` 與 `DEEP_TASK_FILE` 交給 deepclaude，呼叫方自己檔案的即時修改永遠碰不到模型；
`test-deep-run.sh` 現在檢查副本內容、權限與 env 指標（15/15，原 11/11）。代理 harness
預設改成 `deep-harness.md`，驗收區塊失敗會印 `CLAIM_MISMATCH` 且回非零（經真 `wo-verify`
端到端驗證）。新增 `deep-lint` 在派工前排擋任務檔契約——一句任務＋一個唯讀可跑的驗收
區塊＋區塊外一行「預期：」，≤40 行，不寫偏移紀錄。

# 2026-09-15

`deep-run` falls back to `gh auth token` when `~/.creds/kv` has no GitHub token, so a
machine that never set up the kv mirror still lets deep `gh search` for a wheel;
`test-deep-run.sh` checks it (11/11). Docs drop the retired Agent haiku-shell notes and
stop calling royalskynet/deep-agent deleted — it is the public mirror.

`deep-run` 在 `~/.creds/kv` 沒有 GitHub token 時退回 `gh auth token`，沒建 kv 鏡像的機器也能讓
deep `gh search` 找輪子；`test-deep-run.sh` 已加檢查（11/11）。文件移除已退役的 Agent haiku 殼
說明，並不再稱 royalskynet/deep-agent 已刪除——它是公開鏡像。

`deep-run` now configures the proxy instead of inheriting whatever the interactive
launcher defaults to. It pins `deepseek-v4-flash-0731` (deep has no `Agent` tool, so
it never produces subagent traffic and a Pro-class main model costs ~10x for no
measured gain on this workload), prepends the ponytail harness to the main loop, and
turns on the loop guard. Paths are now `$HOME`/`$DC_HOME`-relative and the transcript
directory is derived from the cwd instead of being hardcoded.

`deep-run` 改成主動設定 proxy，而不是沿用互動式 launcher 的預設。釘 `deepseek-v4-flash-0731`
（deep 沒有 `Agent` 工具，不會產生 subagent 流量，主模型上 Pro 在這種用量下貴約 10 倍
而實測沒有對應收益）、把 ponytail harness 前置到主 loop、並開啟 loop guard。路徑改為
`$HOME`／`$DC_HOME` 相對，transcript 目錄由 cwd 推導，不再寫死。

**Corrected metric.** The first pass counted `tool_use` blocks and reported 87% of
rounds as "single-tool". That metric was wrong: a Bash call that chains commands with
`;`, `&&`, `||` or a newline is already a batch. Re-measured over 77 sessions /
1,780 rounds counting shell commands instead, only 35.8% of rounds do one thing
(4.27 commands per round) — the block count overstated the problem 2.5x. The guard
now counts shell commands (`shellUnits()`, quotes and heredoc bodies excluded), and
`DC_GUARD_SINGLES` moves 3 → 4: p90 of a genuine one-command run is 4, and the old
threshold would have nudged 62% of runs, most already batched.

`DC_GUARD_NARRATION` also had a real defect — `narration >= budget` fired on *every*
remaining round once crossed (240 nudges in the worst session). It now fires once per
doubling of the budget: same 28/77 session coverage, 6 nudges max.

Verified by `proxy/test-loop-guard.mjs` (13/13, was 7/7), by re-running the same
77-session corpus through the *shipped* `shellUnits()` (35.8% / 4.27 / p90 4 — the
documented numbers and the running code agree), and by four live `deep-run` arms:

| Arm | Config | Result |
|---|---|---|
| A | defaults | 7 rounds, **0 fires** — deep collapsed the task into shell loops, so nothing was degenerate to nudge |
| B | `SINGLES=2 ROUNDS=3` | 23 rounds, **13 fires** (G1 + G3), task still answered correctly |
| C | `NARRATION=400`, harness on | 5 rounds, **0 fires** — prose went into the file, not into assistant text |
| D | `NARRATION=400`, harness off | 12 requests, 5,141 chars of prose, **1 fire** at 2,088 — the doubling throttle held where `>=` would have fired every remaining round |

Two things the live arms settled that the unit tests could not. First, the guard's
`role:"system"` channel is one Claude Code already uses — dumped request bodies show
its own token-budget notices arriving the same way. Second, **while the harness is on,
deep writes 419–688 characters of prose per run**, so the default `DC_GUARD_NARRATION`
of 3000 effectively never fires; G2 is a backstop for a disabled or ignored harness,
not a routine control.

**A/B at n=8 per arm.** 16 `deep-run` audits of a 12-file fixture with 29 planted
defects, guard on/off, four concurrent, arms interleaved per batch so upstream drift
hits both equally:

| | guard on | guard off |
|---|---|---|
| rounds | 6.6 | 6.6 |
| narration | 2,403 | 2,575 |
| prompt tokens | 156,897 | 162,075 |
| produced the output file | 8/8 | 8/8 |
| defects found | 98% | 99% |

No effect, and the honest reason is in the replay: **across those 16 runs the guard
fired 3 times** (1 batching, 2 narration, 0 rounds). A treatment applied three times
cannot show an effect, so this A/B says nothing about whether the nudges work. Testing
that needs the degenerate tail — 8 of 78 corpus sessions — which at this base rate
means roughly 80 runs, not 16.

What the same 16 runs *do* measure is the metric fix, by replaying both versions of
the guard over their 118 tool rounds:

| | nudges | share of rounds | G1 | G2 |
|---|---|---|---|---|
| before (tool_use blocks, bare `>=`) | 29 | 25% | 18 | 11 |
| after (shell commands, doubling band) | 7 | 6% | 1 | 6 |

22 of 29 nudges were firing on healthy behaviour — mostly G1 scolding rounds that had
already batched their commands into one Bash call. Removing them cost nothing: both
arms produced output in 8/8 runs at 98-99% recall.

Arm B earlier showed deep correctly ignoring G1/G3 on genuinely serial work. That is
the right response, but it means compliance on work that really is batchable is still
untested.

**n=8 的 A/B。** 16 趟 `deep-run` 稽核同一份 12 檔、29 個植入缺陷的 fixture，guard 開／關，
四趟並行，每批兩開兩關交錯，讓上游波動平均落在兩臂：

| | guard 開 | guard 關 |
|---|---|---|
| 輪數 | 6.6 | 6.6 |
| 旁白字數 | 2,403 | 2,575 |
| prompt token | 156,897 | 162,075 |
| 有產出檔案 | 8/8 | 8/8 |
| 找到的缺陷 | 98% | 99% |

沒有差異，而誠實的原因在回放裡：**這 16 趟裡 guard 總共只觸發 3 次**（批次 1、旁白 2、
輪數 0）。施了三次的藥測不出療效，所以這個 A/B 對「nudge 有沒有用」沒有結論。要測那個
得取到退化長尾——78 個 session 裡的 8 個——照這個基礎比率大約要 80 趟，不是 16 趟。

同樣這 16 趟真正能測的是指標修正本身。把新舊兩版 guard 都回放過它們的 118 個工具輪：

| | nudge 次數 | 佔輪次 | G1 | G2 |
|---|---|---|---|---|
| 修正前（算 tool_use block、裸 `>=`） | 29 | 25% | 18 | 11 |
| 修正後（算 shell 指令、翻倍節流） | 7 | 6% | 1 | 6 |

29 次裡有 22 次是對正常行為開罵——多數是 G1 在罵那些早就把指令批次進同一個 Bash call
的輪次。拿掉它們沒有代價：兩臂都是 8/8 有產出、recall 98–99%。

前面的 arm B 顯示 deep 在真正序列相依的工作上正確地無視了 G1／G3。反應是對的，但也代表
「在真的能批次的工作上會不會聽話」仍未測到。

用 `proxy/test-loop-guard.mjs` 驗（13/13，原本 7/7）、把出貨版的 `shellUnits()` 抽出來
重跑同一份 77 session 語料驗（35.8% / 4.27 / p90 4，文件數字與執行中的程式碼一致），
再加四趟實跑 `deep-run`：

| Arm | 設定 | 結果 |
|---|---|---|
| A | 預設 | 7 輪、**0 次觸發**——deep 把任務收成 shell 迴圈，本來就沒有退化可罵 |
| B | `SINGLES=2 ROUNDS=3` | 23 輪、**13 次觸發**（G1＋G3），答案仍正確 |
| C | `NARRATION=400`、harness 開 | 5 輪、**0 次觸發**——文字寫進檔案，不在 assistant text 裡 |
| D | `NARRATION=400`、harness 關 | 12 次請求、5,141 字旁白、**1 次觸發**（累積 2,088 時）——翻倍節流擋住了，舊的 `>=` 會從越線那輪起每輪都噴 |

實跑確認了兩件單元測試做不到的事。第一，guard 用的 `role:"system"` 通道是 Claude Code
本來就在用的——dump 出來的請求內容裡看得到它自己的 token 預算通知走同一條路。第二，
**harness 開著時 deep 整趟只寫 419～688 字旁白**，所以 `DC_GUARD_NARRATION` 預設 3000
實際上不會觸發；G2 是 harness 被關掉或被無視時的保險，不是日常控制。

行為上的**改善**仍未成立——A/B 每組只有 n=2，被雜訊蓋過。arm B 另外顯示 deep 在真正
序列相依的工作上正確地無視了 G1／G3，反應是對的，但也代表「在真的能批次的工作上會不會
聽話」還沒測到。

**指標修正。** 第一版用 `tool_use` block 數算，得到「87% 單發輪」。這個指標是錯的：
同一個 Bash call 用 `;`、`&&`、`||` 或換行串起來，本來就已經是批次。改算 shell 指令數
重測 77 個 session、1,780 輪後，真正只做一件事的輪次只有 35.8%（平均 4.27 條指令／
輪）——block 數高估了問題 2.5 倍。guard 現在改算 shell 指令（`shellUnits()`，引號與
heredoc 內不計），`DC_GUARD_SINGLES` 由 3 調到 4：真正單指令連續段的 p90 就是 4，舊門檻
會對 62% 的連續段開罵，其中多數早就批次過了。

`DC_GUARD_NARRATION` 另有實際缺陷——`narration >= budget` 一旦超過就**每輪都觸發**
（最糟的 session 會噴 240 次）。現在改成每翻倍觸發一次：session 覆蓋率一樣是 28/77，
最多 6 次。

機制已由 `proxy/test-loop-guard.mjs`（13/13，原本 7/7）與實跑 proxy log 驗證。行為上的
**改善**仍未成立——A/B 每組只有 n=2，被雜訊蓋過。

# 2026-09-12

repo 建立，來源收攏自 agent-tools/.claude/.deepclaude。

Repo created; sources consolidated from agent-tools/.claude/.deepclaude.

agent-tools/sbin/deep-run 退役，唯一來源為本 repo。agent-tools/sbin/deep-run retired; this repo is the sole source.
repo 併入 royalskynet/deepclaude 頂層 `deep-agent/`（git subtree，歷史保留）；royalskynet/deep-agent 與 `~/dev/deep-agent` 刪除。symlink 改指 `~/.deepclaude/deep-agent/`。

Merged into royalskynet/deepclaude as top-level `deep-agent/` (git subtree, history kept); royalskynet/deep-agent and `~/dev/deep-agent` deleted. Symlinks now point at `~/.deepclaude/deep-agent/`.
