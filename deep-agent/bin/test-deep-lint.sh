#!/usr/bin/env bash
# Self-check for deep-lint's prose-prohibition warning. No network, no model: two
# fixture task files, one with a 禁令 left in the body and one with it moved into the
# 「## 禁止」 section. Run: deep-agent/bin/test-deep-lint.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/deep-lint-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
rc=0

body() {  # $1 = the 任務 line
  cat <<EOF
# 測試用工單

## 任務

$1

## 驗收

\`\`\`bash
set -e
test -d /
\`\`\`

預期：無輸出，rc=0。

## 禁止

EOF
}

body '把 X 設定改掉。不要手改 settings.json，用 CLI。' > "$tmp/loose.md"
echo '- `launchctl bootout` 必帶完整 service target。' >> "$tmp/loose.md"

body '把 X 設定改掉，走 CLI。' > "$tmp/tight.md"
echo '- 禁手改 settings.json，一律走 CLI。' >> "$tmp/tight.md"

cat <<'EOF' > "$tmp/no-expected.md"
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
test -d /
```
## 禁止
- 禁止改 fixture。
EOF

cat <<'EOF' > "$tmp/fenced-expected.md"
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
預期：這行在 fence 內，不算契約。
test -d /
```
## 禁止
- 禁止改 fixture。
EOF

cat <<'EOF' > "$tmp/one-long.md"
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
test -d /
```
預期：rc=0。
## 禁止
- 禁止改 fixture。
EOF
for i in $(seq 1 35); do printf '補充 %s。\n' "$i" >> "$tmp/one-long.md"; done

cat <<'EOF' > "$tmp/three-tasks.md"
# 測試用工單
## 任務
### 一
完成一。
### 二
完成二。
### 三
完成三。
## 驗收
```bash
test -d /
```
預期：rc=0。
## 禁止
- 禁止改 fixture。
EOF
for i in $(seq 1 45); do printf '補充 %s。\n' "$i" >> "$tmp/three-tasks.md"; done

out=$("$HERE/deep-lint" "$tmp/no-expected.md" 2>&1)
case "$out" in *'缺少 fence 外的「預期：」行'*) echo 'ok: 缺預期會警告';; *) echo "FAIL: 缺預期未警告 — $out"; rc=1;; esac
out=$("$HERE/deep-lint" "$tmp/fenced-expected.md" 2>&1)
case "$out" in *'缺少 fence 外的「預期：」行'*) echo 'ok: fence 內假預期不算';; *) echo "FAIL: fence 內假預期誤判 — $out"; rc=1;; esac
out=$("$HERE/deep-lint" "$tmp/tight.md" 2>&1)
case "$out" in 'LINT OK') echo 'ok: 有預期不誤報';; *) echo "FAIL: 有預期誤報 — $out"; rc=1;; esac
out=$("$HERE/deep-lint" "$tmp/one-long.md" 2>&1)
case "$out" in *'tasks=1, formula=40+20*(tasks-1)'*) echo 'ok: 單任務超限警告';; *) echo "FAIL: 單任務超限未警告 — $out"; rc=1;; esac
out=$("$HERE/deep-lint" "$tmp/three-tasks.md" 2>&1)
case "$out" in 'LINT OK') echo 'ok: 三任務合理長度不警告'; echo 'ok: 多任務合理長度不警告';; *) echo "FAIL: 三任務長度誤報 — $out"; rc=1;; esac

out=$("$HERE/deep-lint" "$tmp/loose.md" 2>&1)
case "$out" in
  *'禁令寫在正文'*) echo "ok: 正文禁令被抓到" ;;
  *) echo "FAIL: 正文禁令沒被抓到 — $out"; rc=1 ;;
esac

out=$("$HERE/deep-lint" "$tmp/tight.md" 2>&1)
case "$out" in
  'LINT OK') echo "ok: 禁令在禁止段時不誤報" ;;
  *) echo "FAIL: 誤報 — $out"; rc=1 ;;
esac

# 探針閘門 fixtures (fix 9356)
body '呼叫 API https://openrouter.ai/api/v1/systemone，POST /。' > "$tmp/probe-url.md"
body '呼叫 API https://openrouter.ai/api/v1/systemone，POST /。探針：http=400 …' > "$tmp/probe-ev.md"
cat <<'EOF' > "$tmp/probe-fenced.md"
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
curl -X POST https://openrouter.ai/api/v1/systemone
```
## 禁止
- 禁止改 fixture。
EOF

out=$("$HERE/deep-lint" "$tmp/probe-url.md" 2>&1)
case "$out" in
  *'無探針證據'*) echo 'ok: 正文有 URL 無探針→警告' ;;
  *) echo "FAIL: URL 無探針未警告 — $out"; rc=1 ;;
esac
out=$("$HERE/deep-lint" "$tmp/probe-ev.md" 2>&1)
case "$out" in
  'LINT OK') echo 'ok: URL 加探針行→無警告' ;;
  *) echo "FAIL: 有探針誤報 — $out"; rc=1 ;;
esac
out=$("$HERE/deep-lint" "$tmp/probe-fenced.md" 2>&1)
case "$out" in
  *'無探針證據'*) echo "FAIL: fence 內 URL 誤報 — $out"; rc=1 ;;
  *) echo 'ok: URL 只在 fence 內→無警告' ;;
esac

# clean-tree 閘門 fixtures (fix 9620)
cat <<'EOF' > "$tmp/clean-noscratch.md"
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
git status --porcelain >/dev/null
[ -z "$(git status --porcelain)" ]
```
預期：rc=0。
## 禁止
- 禁止改 fixture。
EOF
cat <<'EOF' > "$tmp/clean-scratch.md"
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
git status --porcelain >/dev/null
[ -z "$(git status --porcelain)" ]
```
預期：rc=0。
## 不動
- scratch 一律放 $TMPDIR，不進 repo。
EOF

out=$("$HERE/deep-lint" "$tmp/clean-noscratch.md" 2>&1)
case "$out" in
  *'clean-tree 斷言'*) echo 'ok: clean-tree 無 scratch 位置→警告' ;;
  *) echo "FAIL: clean-tree 無 scratch 未警告 — $out"; rc=1 ;;
esac
out=$("$HERE/deep-lint" "$tmp/clean-scratch.md" 2>&1)
case "$out" in
  'LINT OK') echo 'ok: clean-tree 有寫 scratch 位置→不警告' ;;
  *) echo "FAIL: 有 scratch 位置誤報 — $out"; rc=1 ;;
esac

# reporter 閘門 fixtures (fix 9617)
cat <<'EOF' > "$tmp/test-noreporter.md"
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
npm test 2>&1 | grep -E '^# fail' | grep -q '^# fail 0'
```
預期：rc=0。
## 禁止
- 禁止改 fixture。
EOF
cat <<'EOF' > "$tmp/test-reporter.md"
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
npm test -- --test-reporter=tap 2>&1 | grep -E '^# (pass|fail)' | grep -q '^# fail 0'
```
預期：rc=0。
## 禁止
- 禁止改 fixture。
EOF

out=$("$HERE/deep-lint" "$tmp/test-noreporter.md" 2>&1)
case "$out" in
  *'--test-reporter'*) echo 'ok: npm test 無 reporter→警告' ;;
  *) echo "FAIL: npm test 無 reporter 未警告 — $out"; rc=1 ;;
esac
out=$("$HERE/deep-lint" "$tmp/test-reporter.md" 2>&1)
case "$out" in
  'LINT OK') echo 'ok: 有 --test-reporter=tap→不警告' ;;
  *) echo "FAIL: 有 reporter 誤報 — $out"; rc=1 ;;
esac

# ---- 六條新閘門 fixtures (fix 9215/9624, 9341, 9471, 9216, 9478, 9206) ----

# grep -c (fix 9215/9624)
cat <<'EOF' > "$tmp/grepc-bad.md"
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
grep -c foo /etc/hosts
test -d /
```
預期：rc=0。
## 禁止
- 禁止改 fixture。
EOF
cat <<'EOF' > "$tmp/grepc-good.md"
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
[ "$(grep -c foo /etc/hosts)" = 0 ]
grep -c foo /etc/hosts || true
test -d /
```
預期：rc=0。
## 禁止
- 禁止改 fixture。
EOF
out=$("$HERE/deep-lint" "$tmp/grepc-bad.md" 2>&1)
case "$out" in
  *'fix 9215/9624'*) echo 'ok: grep -c 裸用→警告' ;;
  *) echo "FAIL: grep -c 裸用未警告 — $out"; rc=1 ;;
esac
out=$("$HERE/deep-lint" "$tmp/grepc-good.md" 2>&1)
case "$out" in
  'LINT OK') echo 'ok: grep -c 包進 $() 或 || true→不警告' ;;
  *) echo "FAIL: grep -c 安全寫法誤報 — $out"; rc=1 ;;
esac

# pipefail (fix 9341)
cat <<'EOF' > "$tmp/pipefail-bad.md"
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
set -o pipefail
test -d /
```
預期：rc=0。
## 禁止
- 禁止改 fixture。
EOF
cat <<'EOF' > "$tmp/pipefail-good.md"
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
test -d /
```
預期：rc=0。
## 禁止
- 禁止改 fixture。
EOF
out=$("$HERE/deep-lint" "$tmp/pipefail-bad.md" 2>&1)
case "$out" in
  *'fix 9341'*) echo 'ok: 自開 pipefail→警告' ;;
  *) echo "FAIL: pipefail 未警告 — $out"; rc=1 ;;
esac
out=$("$HERE/deep-lint" "$tmp/pipefail-good.md" 2>&1)
case "$out" in
  'LINT OK') echo 'ok: 無 pipefail→不警告' ;;
  *) echo "FAIL: 無 pipefail 誤報 — $out"; rc=1 ;;
esac

# <佔位符> (fix 9471)
cat <<'EOF' > "$tmp/placehold-bad.md"
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
cat <file> > /dev/null
test -d /
```
預期：rc=0。
## 禁止
- 禁止改 fixture。
EOF
cat <<'EOF' > "$tmp/placehold-good.md"
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
cat < /etc/hosts > /dev/null
test -d /
```
預期：rc=0。
## 禁止
- 禁止改 fixture。
EOF
out=$("$HERE/deep-lint" "$tmp/placehold-bad.md" 2>&1)
case "$out" in
  *'fix 9471'*) echo 'ok: <佔位符>→警告' ;;
  *) echo "FAIL: <佔位符> 未警告 — $out"; rc=1 ;;
esac
out=$("$HERE/deep-lint" "$tmp/placehold-good.md" 2>&1)
case "$out" in
  'LINT OK') echo 'ok: 真重導向 < / 不誤報' ;;
  *) echo "FAIL: 真重導向誤報 — $out"; rc=1 ;;
esac

# 憑證變數 (fix 9216)
cat <<'EOF' > "$tmp/cred-bad.md"
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
echo "$MY_TOKEN"
test -d /
```
預期：rc=0。
## 禁止
- 禁止改 fixture。
EOF
cat <<'EOF' > "$tmp/cred-good.md"
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
[ -n "$MY_TOKEN" ] && echo has_token || echo no_token
test -d /
```
預期：rc=0。
## 禁止
- 禁止改 fixture。
EOF
out=$("$HERE/deep-lint" "$tmp/cred-bad.md" 2>&1)
case "$out" in
  *'fix 9216'*) echo 'ok: echo 印憑證變數→警告' ;;
  *) echo "FAIL: echo 印憑證變數未警告 — $out"; rc=1 ;;
esac
out=$("$HERE/deep-lint" "$tmp/cred-good.md" 2>&1)
case "$out" in
  'LINT OK') echo 'ok: 印布林不誤報' ;;
  *) echo "FAIL: 印布林誤報 — $out"; rc=1 ;;
esac

# 一級標題 (fix 9478)
cat <<'EOF' > "$tmp/h1-bad.md"
# 測試用工單
# 任務
完成 fixture。
## 驗收
```bash
test -d /
```
預期：rc=0。
## 禁止
- 禁止改 fixture。
EOF
cat <<'EOF' > "$tmp/h1-good.md"
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
test -d /
```
預期：rc=0。
## 禁止
- 禁止改 fixture。
EOF
out=$("$HERE/deep-lint" "$tmp/h1-bad.md" 2>&1)
case "$out" in
  *'fix 9478'*) echo 'ok: 一級段落標題→警告' ;;
  *) echo "FAIL: 一級標題未警告 — $out"; rc=1 ;;
esac
out=$("$HERE/deep-lint" "$tmp/h1-good.md" 2>&1)
case "$out" in
  'LINT OK') echo 'ok: 二級標題不誤報' ;;
  *) echo "FAIL: 二級標題誤報 — $out"; rc=1 ;;
esac

# date -u (fix 9206)
cat <<'EOF' > "$tmp/utc-bad.md"
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
d=$(date -u +%F)
test -d /
```
預期：rc=0。
## 禁止
- 禁止改 fixture。
EOF
cat <<'EOF' > "$tmp/utc-good.md"
# 測試用工單
## 任務
完成 fixture。
## 驗收
```bash
d=$(date +%F)
test -d /
```
預期：rc=0。
## 禁止
- 禁止改 fixture。
EOF
out=$("$HERE/deep-lint" "$tmp/utc-bad.md" 2>&1)
case "$out" in
  *'fix 9206'*) echo 'ok: date -u→警告' ;;
  *) echo "FAIL: date -u 未警告 — $out"; rc=1 ;;
esac
out=$("$HERE/deep-lint" "$tmp/utc-good.md" 2>&1)
case "$out" in
  'LINT OK') echo 'ok: date +%F 不誤報' ;;
  *) echo "FAIL: date +%F 誤報 — $out"; rc=1 ;;
esac

exit "$rc"
