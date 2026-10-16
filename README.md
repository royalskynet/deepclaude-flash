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

Needs `claude` (Claude Code CLI), `node` ≥ 18 and `bash`. macOS and Linux.
需要 `claude`（Claude Code CLI）、`node` ≥ 18、`bash`。支援 macOS 與 Linux。

## Use / 使用

```bash
export CHEAPERINFERENCE_API_KEY=...   # default backend / 預設後端
deepclaude                            # start Claude Code on DeepSeek Flash
deepclaude -b ds                      # DeepSeek official API (DEEPSEEK_API_KEY)
deepclaude -b or                      # OpenRouter (OPENROUTER_API_KEY)
deepclaude -b fw                      # Fireworks (FIREWORKS_API_KEY)
deepclaude --status                   # show backend, keys (masked), models
```

Keys can also live in `~/.creds/kv/<VAR>.txt`; the launcher loads them if present.
API key 也可以放在 `~/.creds/kv/<變數名>.txt`，啟動時會自動讀取。

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
