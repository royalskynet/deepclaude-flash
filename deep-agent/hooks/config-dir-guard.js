#!/usr/bin/env node
/* config-dir-guard — PreToolUse(Bash) 硬 deny：隔離實例裡漏 env -u 的 claude 子命令。
 *
 * 目的（本機修理日誌三筆同根，2026-09-29 第四次復發）：
 * deep 跑在 CLAUDE_CONFIG_DIR=~/.deepclaude/config 底下，任何 `claude plugin|mcp|config`
 * 子命令都寫進那份 config，而非主機 ~/.claude。後果有二：
 *   1. 主機該生效的設定沒生效，deep 的自我驗收卻必然通過（自證式驗收，錯不出來）；
 *   2. ~/.deepclaude/config/settings.json 是跨機共用契約檔，被塞進 使用者家目錄絕對路徑後
 *      其他機器拉下去即壞（2026-09-29 實例：3 條 secret-cheeragent hook + jev-gate 改本地 directory）。
 * 前三次的修法都是「工單寫 env -u CLAUDE_CONFIG_DIR」＝ Documentation 層，符合率 ~0%，故升級為 deny。
 *
 * 規則刻意窄：
 *   - 只在 process.env.CLAUDE_CONFIG_DIR 有值時作用。主機 session 沒設這個變數 → 一律放行，零影響。
 *   - 只認 claude 的 plugin / mcp / config 三個會寫設定檔的子命令；claude -p、claude --help 等不管。
 *   - 指令以 ; && || | 換行切段，逐段判；該段自帶 `env -u CLAUDE_CONFIG_DIR` 或
 *     明確 `CLAUDE_CONFIG_DIR=...` 前綴 → 放行（已表態要寫哪份 config）。
 *   - 逃生門：指令任一處含 `# deep-config-intentional` → 放行（真的要改 deep 自己的 config）。
 * 解析失敗或非 Bash → 無輸出 exit 0（fail-open：narrow hook 壞掉不可拖垮所有 Bash）。
 * 測試：node config-dir-guard.selfcheck.js
 */

const RE_CLAUDE_WRITE = /\bclaude\s+(?:-{1,2}\S+\s+)*(plugin|mcp|config)\b/;
const RE_UNSET = /\benv\s+(?:-\S+\s+)*-u\s+CLAUDE_CONFIG_DIR\b/;
const RE_EXPLICIT = /(?:^|[;&|]\s*|\s)CLAUDE_CONFIG_DIR=/;
const RE_ESCAPE = /#\s*deep-config-intentional\b/;

function hits(cmd) {
  const s = String(cmd);
  if (RE_ESCAPE.test(s)) return null;
  for (const seg of s.split(/[;&|\n]+/)) {
    const m = seg.match(RE_CLAUDE_WRITE);
    if (!m) continue;
    if (RE_UNSET.test(seg) || RE_EXPLICIT.test(seg)) continue;
    return m[1];
  }
  return null;
}

function deny(reason) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  }));
}

if (require.main === module) {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', c => { data += c; });
  process.stdin.on('end', () => {
    try {
      if (!process.env.CLAUDE_CONFIG_DIR) return;
      const payload = JSON.parse(data || '{}');
      if (payload.tool_name !== 'Bash') return;
      const cmd = payload.tool_input && payload.tool_input.command;
      if (typeof cmd !== 'string') return;
      const sub = hits(cmd);
      if (!sub) return;
      deny(`此 session 的 CLAUDE_CONFIG_DIR=${process.env.CLAUDE_CONFIG_DIR}，`
        + `\`claude ${sub}\` 會寫進這份隔離 config 而不是主機 ~/.claude，`
        + `而且你的驗收在同一組環境變數下跑、必然通過。`
        + `要改主機設定：前綴 \`env -u CLAUDE_CONFIG_DIR\`，並由主 session 在自己環境重跑一次驗收。`
        + `真要改這份隔離 config：指令加註解 \`# deep-config-intentional\`。`
        + `注意 ~/.deepclaude/config/settings.json 是跨機共用契約檔，不得寫入含絕對路徑的本機設定。`);
    } catch { /* fail-open */ }
  });
  setTimeout(() => process.exit(0), 1500).unref();
}

module.exports = { hits, RE_CLAUDE_WRITE, RE_UNSET, RE_EXPLICIT, RE_ESCAPE };
