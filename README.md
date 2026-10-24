# deepclaude-flash

Run Claude Code against cheap DeepSeek **Flash** models through a local translating proxy, in an isolated config dir that never touches your `~/.claude`.

以本機轉譯 proxy 讓 Claude Code 改用便宜的 DeepSeek **Flash** 模型，並使用獨立設定目錄，不會動到你的 `~/.claude`。

> Fork of [aattaran/deepclaude](https://github.com/aattaran/deepclaude) (MIT), heavily modified.
> 改自 [aattaran/deepclaude](https://github.com/aattaran/deepclaude)（MIT），大幅修改。
>
> **Status / 狀態**: the author stopped using it day-to-day in 2026-10; issues may go unanswered.
> 作者本人自 2026-10 起已停用，issue 可能不會回覆。

## Quick install / 快速安裝

```bash
git clone https://github.com/royalskynet/deepclaude-flash ~/.deepclaude && mkdir -p ~/.local/bin && ln -sf ~/.deepclaude/bin/deepclaude ~/.local/bin/deepclaude
```

Needs `claude` (Claude Code CLI), `node` ≥ 18 and `bash`. macOS and Linux; Windows works from Git Bash.
需要 `claude`（Claude Code CLI）、`node` ≥ 18、`bash`。支援 macOS 與 Linux；Windows 可在 Git Bash 下執行。

## Set up a key / 設定 API key

Installing asks nothing. The **first time you run `deepclaude` in a terminal** without a key, it asks for one (input hidden) and saves it. Run `deepclaude --setup` any time to pick a backend and change the key.
安裝時不會問任何東西。**第一次在終端機執行 `deepclaude`** 而還沒有 key 時，會請你貼上 key（輸入不顯示）並存起來。之後隨時可執行 `deepclaude --setup` 換後端或換 key。

```bash
deepclaude --setup        # menu: 1) ds  2) go  3) fw
deepclaude --setup ds     # skip the menu
```

**Recommended: a DeepSeek API key** (`ds`, model `deepseek-v4-flash`). Pay-as-you-go, no subscription, cheapest of the three. Get one at <https://platform.deepseek.com/api_keys>.
**建議用 DeepSeek 官方 API key**（`ds`，模型 `deepseek-v4-flash`）：用多少付多少、不用訂閱，三者中最便宜。到 <https://platform.deepseek.com/api_keys> 申請。

| Backend | Key | Model | Notes |
|---|---|---|---|
| `ds` (recommended) | `DEEPSEEK_API_KEY` | `deepseek-v4-flash` | DeepSeek official, pay-as-you-go |
| `go` (default if never set up) | `OPENCODE_ZEN_API_KEY` | `deepseek-v4.1-flash` | OpenCode Go subscription |
| `fw` | `FIREWORKS_API_KEY` | `deepseek-v4-flash` | Fireworks |

Where keys are read from, first match wins: environment variable, then `~/.creds/kv/<VAR>.txt` (one value per file; `--setup` writes here). Keys are never passed on the command line, because other programs can read argv via `ps`.
key 讀取順序：先看環境變數，再看 `~/.creds/kv/<變數名>.txt`（一檔一值，`--setup` 就是寫這裡）。key 不走命令列參數，因為其他程式能用 `ps` 看到參數。

In scripts or CI (no terminal), nothing is asked: a missing key stops with `ERROR: <VAR> not set (run: deepclaude --setup)`.
在腳本或 CI（沒有終端機）裡不會詢問；缺 key 時直接停下並顯示 `ERROR: <VAR> not set (run: deepclaude --setup)`。

### Other models / 其他模型

Any model whose endpoint speaks the Anthropic Messages API can drive Claude Code. The hard requirement is reliable tool calling. DeepSeek Flash is the tested default. To try another model on the same backend, set `OPENCODE_GO_MODEL` (for `go`) or `FIREWORKS_MODEL` (for `fw`) and check it on a small task first. Only DeepSeek **Pro** ids are refused (see below).
只要端點支援 Anthropic Messages API，就能拿來跑 Claude Code，硬條件是工具呼叫要穩。DeepSeek Flash 是實測過的預設。要在同一個後端換模型，設 `OPENCODE_GO_MODEL`（`go`）或 `FIREWORKS_MODEL`（`fw`），先用小任務驗證。只有 DeepSeek **Pro** 會被拒絕（見下節）。

## Use / 使用

```bash
deepclaude                            # start Claude Code on the default backend
deepclaude -b ds                      # one-off: DeepSeek official API
deepclaude -b go                      # one-off: OpenCode Go
deepclaude --status                   # show backend, keys (masked), models
```

`ci` (CheaperInference) was retired on 2026-10-18. `or` (OpenRouter) is disabled in this build: the launcher unsets `OPENROUTER_API_KEY`.
`ci`（CheaperInference）已於 2026-10-18 退役。`or`（OpenRouter）在此版停用：啟動器會清掉 `OPENROUTER_API_KEY`。

## Flash-only policy / 只准 Flash

Every backend defaults to a DeepSeek Flash model, and the launcher, the resident proxy and the in-proxy model remap all refuse any DeepSeek **Pro** id, even when set via env. To lift this, edit the guard in `repo/deepclaude.sh` and `bin/deepclaude-proxyd`.

所有後端預設都用 DeepSeek Flash；啟動器、常駐 proxy、proxy 內的模型對應都會拒絕 DeepSeek **Pro**，用環境變數指定也一樣。要解除請改 `repo/deepclaude.sh` 與 `bin/deepclaude-proxyd` 裡的檢查。

## Layout / 結構

| Path | What / 用途 |
|---|---|
| `bin/deepclaude` | Launcher: own `CLAUDE_CONFIG_DIR`, loads keys, runs the router. 啟動器 |
| `repo/deepclaude.sh` | Backend router (ci / ds / or / fw / omni / anthropic), spawns a per-session proxy. 後端路由 |
| `repo/proxy/` | Anthropic API ⇄ backend translating proxy, with tests (`node repo/proxy/test-*.mjs`). 轉譯 proxy |
| `bin/deepclaude-proxyd`, `launchd/` | Optional resident proxy for `happy` phone sessions (macOS launchd). 選用：常駐 proxy |
| `bin/deep-run`, `bin/deep-lint`, `bin/wo-verify`, `hooks/`, `skills/deep/`, `config/deep-*.md` | Built-in `deep` dispatch: hand a task with one acceptance command to a headless deepclaude runner; `wo-verify` decides pass/fail, the stop gate blocks exit until it passes. Link `skills/deep` into `~/.claude/skills/` and `bin/deep-run` onto `PATH`. 內建派工（派deep） |
| `bin/dc-stats`, `bin/dc-restart` | Usage readout; clean restart of the launchd stack. 用量統計、重啟 |

## License / 授權

MIT — see `LICENSE` (original copyright Ali Attaran).
MIT，見 `LICENSE`（原著作權 Ali Attaran）。
