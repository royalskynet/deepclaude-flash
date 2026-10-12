---
description: 派工 deep — 像派 sonnet 一樣：有計畫 md 就直接 deep-run 那份計畫，沒有才把 $ARGUMENTS 寫成三段任務檔。deep 自己查舊帳、gh 找輪子、做完、驗證、回報
argument-hint: '[計畫 md 絕對路徑，或要給 deep 做的任務]'
---
deep 是自主執行者，不設能力上限：搜尋／枚舉／改檔／git／launchd／寫沙箱擋的路徑全自己做，先 `fixindex find` 再 `gh search` 找輪子，抄不寫。

## 動作
1. 決定任務檔：
   - 派工前先 `deep-lint <task.md>`；任務檔契約＝一句任務＋一個驗收 shell 區塊（唯讀斷言、失敗非零）＋區塊外「預期：」一行＋可省的不動段，≤40 行，不寫「上次偏移紀錄」。
   - **主 session 剛出過計畫 md**（或 `$ARGUMENTS` 是 md 絕對路徑）→ 任務檔＝那份計畫，**不重寫、不摘要**。計畫沒驗收段就 append 一行「驗收：<一條指令＋期望>」。
   - 沒計畫 → scratchpad `deep/<slug>.md` 三段：**任務**（原文＋絕對路徑、限制）、**驗收**（一條可重跑指令＋期望；想不出寫「自訂驗收並貼輸出」）、**不動**（可省）。不寫步驟、不寫指令。含憑證路徑字串用 Write tool。
2. Bash 單一原子指令 `deep-run <任務檔絕對路徑> <cwd>`（**裸名** deep-run，絕對路徑會掉回沙箱 exit 3；禁 pipe／&&／$()；timeout 600000；預估 >2 分鐘加 `run_in_background: true`）。
3. 驗收：重跑驗收指令；`tail -2 "$WLOG"`（預設 `~/Library/Logs/openclaw/wrappers.log`） 有 `deep-run start`／`end rc=`。回報缺段就讀 deepclaude transcript 的 tool_result。
4. 回使用者：一句結果＋deep 用的輪子 URL＋驗收輸出原文（原文不摘要）。

## 判準
- `$ARGUMENTS` 為空且沒剛出的計畫 → 回問要派什麼。
- 只有需要 Opus 級權衡的決策留主 session，其餘全派。`/deep` 走本檔 Bash 直呼，可 background；派工一律 Bash 裸呼 `deep-run`。
