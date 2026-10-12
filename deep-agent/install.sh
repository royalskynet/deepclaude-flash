#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"

mkdir -p ~/.local/bin ~/.claude/skills ~/.claude/commands

ln -sfn "$REPO/bin/deep-run" ~/.local/bin/deep-run
ln -sfn "$REPO/bin/deep-lint" ~/.local/bin/deep-lint
ln -sfn "$REPO/bin/api-probe" ~/.local/bin/api-probe
ln -sfn "$REPO/bin/wo-verify" ~/.local/bin/wo-verify

# ~/.claude/skills/deep: if it is a real directory, back it up inside the repo before linking
if [ -d ~/.claude/skills/deep ] && [ ! -L ~/.claude/skills/deep ]; then
  mkdir -p "$REPO/.bak"
  mv ~/.claude/skills/deep "$REPO/.bak/deep-$(date +%Y%m%d)"
fi
ln -sfn "$REPO/claude/skills/deep" ~/.claude/skills/deep

ln -sfn "$REPO/claude/commands/deep.md" ~/.claude/commands/deep.md

mkdir -p ~/.deepclaude/config/hooks
ln -sfn "$REPO/hooks/deep-stop-gate.sh" ~/.deepclaude/config/hooks/deep-stop-gate.sh
ln -sfn "$REPO/hooks/config-dir-guard.js" ~/.deepclaude/config/hooks/config-dir-guard.js

echo "Installed symlinks:"
for t in ~/.local/bin/deep-run ~/.local/bin/deep-lint ~/.local/bin/api-probe ~/.local/bin/wo-verify ~/.claude/skills/deep ~/.claude/commands/deep.md ~/.deepclaude/config/hooks/deep-stop-gate.sh ~/.deepclaude/config/hooks/config-dir-guard.js; do
  ls -l "$t"
  [ -e "$t" ] || { echo "DANGLING: $t (fix 9625)"; exit 1; }
done