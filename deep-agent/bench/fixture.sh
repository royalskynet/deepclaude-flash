#!/usr/bin/env bash
# fixture.sh <a|b|c> <dir> — 在呼叫端給的空目錄 (<dir>) 建固定 fixture 並 git init+commit。
#   a：hello.sh 印 hi（缺 chmod +x）
#   b：README.md 一行含「內部」；驗收自相矛盾（見 task-b.md）
#   c：forbidden-words.md 含「內部」+ SSOT.md 要求逐字保留
set -euo pipefail
x="${1:?用法: fixture.sh <a|b|c> <dir>}"
d="${2:?fixture.sh: 缺 <dir>}"
[ -d "$d" ] && [ -z "$(ls -A "$d")" ] || { echo "fixture.sh: <dir> 需為空目錄: $d" >&2; exit 2; }
case "$x" in
  a) printf '#!/usr/bin/env bash\nprintf "hi\\n"\n' > "$d/hello.sh" ;;
  b) printf '內部\n' > "$d/README.md" ;;
  c)
    printf '內部\n' > "$d/forbidden-words.md"
    printf 'forbidden-words.md 必須逐字保留 `內部`\n' > "$d/SSOT.md"
    ;;
  *) echo "fixture.sh: 未知類型 $x" >&2; exit 2 ;;
esac
git -C "$d" init -q
git -C "$d" add -A
git -C "$d" commit -qm init