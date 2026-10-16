#!/usr/bin/env node
/* selfcheck for config-dir-guard：該擋的擋、該放的放。跑法：node config-dir-guard.selfcheck.js */
const assert = require('assert');
const { hits } = require('./config-dir-guard.js');

const BLOCK = [
  'claude plugin install foo@bar',
  'claude mcp add -s user beacon beacon',
  'claude config set -g foo bar',
  'cd /tmp && claude plugin marketplace add /opt/dev/y',
  'echo hi; claude mcp list',
];
const ALLOW = [
  'env -u CLAUDE_CONFIG_DIR claude plugin install foo@bar',
  'CLAUDE_CONFIG_DIR=$HOME/.claude claude mcp add -s user beacon beacon',
  'claude plugin install foo@bar  # deep-config-intentional',
  'claude -p "解釋這段"',
  'claude --help',
  'git commit -m "claude mcp add 的說明"'.replace('claude mcp add', 'claude-mcp-add'),
  'env -u CLAUDE_CONFIG_DIR claude mcp list && echo done',
];

for (const c of BLOCK) assert.ok(hits(c), `應擋卻放行: ${c}`);
for (const c of ALLOW) assert.strictEqual(hits(c), null, `應放行卻擋: ${c}`);

// 多段指令：只要有一段沒帶 env -u 就擋
assert.ok(hits('env -u CLAUDE_CONFIG_DIR claude mcp list; claude plugin install x'),
  '混合指令中未保護的那段應被擋');

console.log(`OK: ${BLOCK.length} 擋 / ${ALLOW.length} 放 / 混合指令 1，全數符合`);
