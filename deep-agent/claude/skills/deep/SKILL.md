---
name: deep
description: 派工給 deep 執行人（deepclaude/CheaperInference，沙箱外、可寫任何路徑）：主 session 給計畫或一句任務＋一條驗收，deep 自主查 fixindex、gh 找輪子、做完驗證回報。說「派工 deep」「派 deep」「deep 去查」「/deep」時用。
---
# deep = 自主執行者，主 session = 出題＋驗收

**分工（2026-09-12 v2）**：主 session 只出題（計畫或一句任務）＋驗收，不寫執行指令。方法論（先查舊帳 → gh 找輪子 → 最小改動 → 可重跑驗證）在 `$DC_HOME/config/deep-system.md`，deep 自己跑。deep 經 `deep-run` 在**沙箱外**跑，能寫 `~/.claude/**`、`.git/config` 等沙箱擋的路徑。

## 任務檔
- **派工前先 `deep-lint <task.md>`**；任務檔契約＝一句任務＋一個驗收 shell 區塊（唯讀斷言、失敗非零）＋區塊外「預期：」一行＋可省的不動段，≤40 行，不寫「上次偏移紀錄」。
- **常態：主 session 剛出過計畫 md** → 任務檔＝那份計畫（絕對路徑），**不重寫、不摘要、不拆步驟**。計畫缺驗收就 append 一行「驗收：<一條指令＋期望>」。
- **沒計畫** → scratchpad `deep/<slug>.md` 三段：**任務**（原文＋deep 不可能自己知道的前情：絕對路徑、限制、期望格式）／**驗收**（一條可重跑指令＋期望；想不出寫「自訂驗收並貼輸出」）／**不動**（可省）。
- **驗收段每一步都要寫「預期輸出」**（指令＋它應該印出什麼）。沒有預期輸出的步驟等於邀請 deep 亂猜：它無法判斷成功與否，就會一直換做法試到「看起來對」為止。任務檔沒寫死的事，deep 一律不做——路徑、設定鍵、旗標、模型名要用就寫全，不留「照慣例」「自己找一下」。
- 含憑證路徑字串（如 `.creds/*/.env`）用 Write tool 寫，Bash heredoc 會被 creds-egress-guard 攔。
- **每份任務檔末尾固定附「## 禁止」段**，至少含兩條：
  1. 「`launchctl bootout/bootstrap/kickstart` 必帶完整 service target `gui/$(id -u)/<label>`；裸 domain 與 `launchctl reboot` 禁止；載入回 141/125 立即停手回報」（曾有一次裸跑 `bootout gui/<uid>` 拆掉整個登入 session，無頭機無法自救）。任務若涉及 launchd 載入，指令寫全、不留「照 fixindex 慣例」之類的省略。
  2. 「無頭機：禁止回報『請使用者手動貼 token／授權／執行指令』。憑證讀不到＝停手回報阻斷點與需要的 key 名，不要求人工補值。」

## 派工（唯 Bash 裸呼）
- **Bash 直呼**：主 session 用 `run_in_background` 自己控進度、或指定 cwd／串多個任務。
- `deep-run <task.md> <cwd>`，**裸名**（絕對路徑不匹配 excludedCommands 會掉回沙箱，deep-run 會 exit 3 提示），單一原子指令（禁 pipe／&&／$()／heredoc 同 call；timeout 600000）。預估 >2 分鐘 → `run_in_background: true`。
- deep 工具：Bash／Read／Edit／Write／Glob／Grep；`gh` 走 deep-run 注入的 `GH_TOKEN`（kv 鏡像；缺檔時退回 `gh auth token`）。任務不得要求 Agent／WebFetch／WebSearch／MCP。
- 每轉前綴約 5.5k tokens；長任務照派，成本在 DeepSeek 端。

## 驗收
- 主 session 重跑驗收指令；宣告 ≠ 生效。
- `tail -2 "$WLOG"`（預設 `~/Library/Logs/openclaw/wrappers.log`） 應有 `deep-run start`／`end rc=`。
- deep 回報偶爾吞段 → 以 transcript 為準：`deep-run` 收尾已印 `tool_use=` 與 `last_tool_result:`；要全文就讀 `~/.deepclaude/config/projects/<cwd-slug>/*.jsonl`（slug＝cwd 把 `/` 與 `.` 都換成 `-`），`jq` 取 `tool_result`。

## 已知坑（實測，2026-09-24）

- **任務檔標題一律 `##`**。`deep-lint` 只認二級標題劃分段落；寫成 `# 禁止` 會被判定「禁令寫在正文」而 WARN，deep 也可能不認那段。
- **`gh` 必須單獨原子指令**。deep 端 wrapper hook 擋非原子命令，`gh ... | head`、`gh ... && ...` 會被拒；拆成獨立一次呼叫。
- **腳本吃的環境變數要在任務檔寫死絕對路徑**。例：research skill 的 `RESEARCH_BUDGET` 不設就回退吃 cwd 的 `./.research-budget.json`，cwd 一偏就扣錯帳或完全不記帳。凡「不設就有預設值」的變數，一律當成必填。
- **沙箱假陰性不得寫進任務檔當前提**。主 session 沙箱連不出去的 host（實測 `r.jina.ai` 回 `URLError`）在 deep 端正常 200。不要因為主 session 試不通就在任務檔裡預先排除某通道，交給 deep 實測。
- **`verify=pass` 只證明斷言，不證明沒改壞**（實測，2026-09-26）。deep 會順手刪掉既有 env 覆寫（`process.env.X || 預設`）、改亂註解、漏 import 只在另一平台分支才炸。`# 驗收` 要含：(1) 必須保留的既有行為的 `grep -q` 斷言；(2) 至少一條真實 CLI 端到端指令（不只單元測試）。主 session 收件後仍看 `git diff`。
- **wo-verify 失敗會印 `wo-verify FAIL line N: <cmd>`**，N＝驗收區塊內行號，先看那行是不是驗收寫錯再懷疑 deep。
- **驗收區塊寫法**：`grep -c` 包進 `$( )` 或 `|| true`、預期失敗的指令寫 `rc=0; cmd || rc=$?; [ "$rc" = 1 ]`、不自開 pipefail、不留 `<佔位符>`。
- **deep 端自 09-26 起驗收走 `wo-verify "$DEEP_TASK_FILE"`**，不 inline。
- **背景 deep-run 的 liveness 判準（2026-09-29 實測）**：`deep-run` 的 stdout 在跑完前幾乎是空的，**空 output ≠ 卡住**。正常時長：paymonade 14m51s、另一次 RN 搜尋 15m（46 次工具呼叫）。判活在三個地方看：(1) `tail -2 "$WLOG"` 有 `deep-run start` 且尚無 `end`；(2) transcript `~/.deepclaude/config/projects/<cwd-slug>/*.jsonl` 的 mtime 還在動；(3) `tmux -L deep ls` 有 `deep-<epoch>` session。三者皆停滯才叫卡住。**殺掉前先讀** `~/.deepclaude/work/.deep/stop-gate/gate.log`：出現 `block` 代表 deep 想收尾但驗收沒過、正在重試，不是當機。
- **驗收必須在「目標不存在」時也能通過**：驗收若寫 `[ -n "$FOUND" ]` 而目標可能不在本機 → `wo-verify` 永遠非零 → Stop gate 每 session 擋一次、deep 空轉到 `DC_GUARD_ROUNDS`（實測 2026-09-29：被誤判為「卡住」，其實 deep 已完成 90%）。目標可能不存在的任務，驗收要斷言「有回報」（例 `grep -q "找不到" "$REPORT"`）而非「目標存在」。

## 不做
- 需要 Anthropic 推理深度的決策（設計權衡、含糊需求解讀）留主 session。
- deep-run 是沙箱逃生門：任務內禁 `set -x`、禁印憑證值（deepclaude 端掛同一支 `creds-egress-guard.js`；**deep-run 不得加 `--bare`**，會跳過 hooks）。
