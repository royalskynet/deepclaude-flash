---
name: deep
description: 派工給 deep 執行人（deepclaude/OpenCode Go，沙箱外、可寫任何路徑）：主 session 給計畫或一句任務＋一條驗收，deep 自主查 fixindex、gh 找輪子、做完驗證回報。只在說「派deep」「派 deep」「deep 去查」時用；一般「派工」走派o（dispatch-router），不是這裡。
---
# deep = 自主執行者，主 session = 出題＋驗收

主 session 只出題＋驗收，不寫執行步驟；方法論在 `$DC_HOME/config/deep-system.md`，deep 自己跑。deep 經 `deep-run` 在**沙箱外**跑，能寫 `~/.claude/**`、`.git/config` 等沙箱擋的路徑。

## 任務檔

- **派前先 `deep-lint <task.md>`**，WARN 照它的提示修完再派（段落標題 `##`、`預期：` 行、行數上限、禁令要進 `## 禁止`、驗收寫法都由它檢查）。
- **剛出過計畫 md** → 任務檔就是那份計畫（絕對路徑），不重寫、不摘要；缺驗收就 append「驗收：<一條指令＋期望>」。
- **沒計畫** → scratchpad `deep/<slug>.md`：`## 任務`（原文＋deep 不可能自己知道的前情）／`## 驗收`（一條可重跑指令）／`## 不動`（可省）。
- **寫死一切**：任務檔沒寫的事 deep 不做。路徑、設定鍵、旗標、模型名寫全；「不設就有預設值」的環境變數一律當必填寫絕對值；驗收每步附預期輸出。
- **主 session 試不通不算數**：沙箱連不出的 host 在 deep 端常是通的，別在任務檔預先排除通道。
- 含憑證路徑字串（如 `.creds/*/.env`）的任務檔用 Write tool 寫，Bash heredoc 會被 creds-egress-guard 攔。
- **每份任務檔末尾附 `## 禁止`**，至少兩條：
  1. `launchctl bootout/bootstrap/kickstart` 必帶完整 service target `gui/$(id -u)/<label>`；裸 domain 與 `launchctl reboot` 禁止；載入回 141/125 立即停手回報。涉及 launchd 的指令寫全。
  2. 無頭機：禁止回報「請使用者手動貼 token／授權／執行指令」；憑證讀不到＝停手回報阻斷點與需要的 key 名。

## 驗收怎麼寫

- `verify=pass` 只證明斷言：要含 (1) 必須保留的既有行為 `grep -q` 斷言；(2) 至少一條真實 CLI 端到端指令。收件後仍看 `git diff`。
- 目標可能不在本機時，斷言「有回報」（例 `grep -q "找不到" "$REPORT"`），不斷言「目標存在」，否則 Stop gate 反覆擋、deep 空轉到 `DC_GUARD_ROUNDS`。
- deep 端驗收走 `wo-verify "$DEEP_TASK_FILE"`；失敗印 `wo-verify FAIL line N: <cmd>`，先查那行是不是驗收寫錯。

## 派工（Bash 裸呼）

- `deep-run <task.md> <cwd>`：**裸名**（絕對路徑會掉回沙箱，exit 3），單一原子指令（同 call 禁 pipe／&&／$()／heredoc），timeout 600000；預估 >2 分鐘用 `run_in_background: true`。
- deep 工具只有 Bash／Read／Edit／Write／Glob／Grep，任務不得要求 Agent／WebFetch／WebSearch／MCP。`gh` 用 deep-run 注入的 `GH_TOKEN`，且必須單獨一次呼叫（`gh ... | head` 會被 deep 端 hook 拒）。
- 安全：任務內禁 `set -x`、禁印憑證值；**deep-run 不得加 `--bare`**（會跳過 hooks，含 creds-egress-guard）。

## 收件與判活

- 主 session 重跑驗收；宣告 ≠ 生效。`tail -2 "$WLOG"`（預設 `~/Library/Logs/openclaw/wrappers.log`）應有 `deep-run start`／`end rc=`。
- 回報吞段以 transcript 為準：`deep-run` 收尾印 `tool_use=`、`last_tool_result:`；全文在 `~/.deepclaude/config/projects/<cwd-slug>/*.jsonl`（slug＝cwd 的 `/` 與 `.` 換成 `-`），`jq` 取 `tool_result`。
- 背景跑時 stdout 空 ≠ 卡住（正常可跑 15 分鐘）。三處皆停滯才算卡住：`$WLOG` 有 start 無 end、transcript mtime 不動、`tmux -L deep ls` 無 `deep-<epoch>`。殺前先讀 `~/.deepclaude/work/.deep/stop-gate/gate.log`，有 `block`＝驗收沒過在重試。

## 不做

- 需要 Anthropic 推理深度的決策（設計權衡、含糊需求解讀）留主 session。
