const fs = require('fs');

const serverPath = '/home/collegeagent/collegeagent/server.js';
let serverCode = fs.readFileSync(serverPath, 'utf8');

// Revert allToolCalls.push to NOT include id
const pushStrNew = `          // Persist tool call record
          allToolCalls.push({
            id: tc.id,
            name: fnName,
            args: fnArgs,
            result: (resultForAgent || '').slice(0, 4000), // cap to avoid bloating storage
            intermediateText: streamContent && streamContent.trim() ? streamContent : null,
            duration,
          });`;
const pushStrOld = `          // Persist tool call record
          allToolCalls.push({
            name: fnName,
            args: fnArgs,
            result: (resultForAgent || '').slice(0, 4000), // cap to avoid bloating storage
            intermediateText: streamContent && streamContent.trim() ? streamContent : null,
            duration,
          });`;

if (serverCode.includes(pushStrNew)) {
  serverCode = serverCode.replace(pushStrNew, pushStrOld);
  console.log('Reverted allToolCalls.push');
}

// Revert apiMessages history mapping
const mapStrNew = `    const apiMessages = [
      { role: 'system', content: fullSystemPrompt },
    ];
    for (const m of history) {
      if (m.role === 'assistant' && m.meta?.toolCalls) {
        for (const tc of m.meta.toolCalls) {
          const tcId = tc.id || require('crypto').randomUUID();
          apiMessages.push({
            role: 'assistant',
            content: tc.intermediateText || null,
            tool_calls: [{
              id: tcId,
              type: 'function',
              function: { name: tc.name, arguments: JSON.stringify(tc.args) }
            }]
          });
          apiMessages.push({
            role: 'tool',
            tool_call_id: tcId,
            content: tc.result || 'null'
          });
        }
      }
      apiMessages.push({ role: m.role, content: m.text });
    }`;
const mapStrOld = `    const apiMessages = [
      { role: 'system', content: fullSystemPrompt },
      ...history.map((m) => ({ role: m.role, content: m.text })),
    ];`;

if (serverCode.includes(mapStrNew)) {
  serverCode = serverCode.replace(mapStrNew, mapStrOld);
  console.log('Reverted apiMessages mapping');
}

fs.writeFileSync(serverPath, serverCode);
console.log('server.js reverted');

// Also revert AGENTS.md
const agentsPath = '/home/collegeagent/collegeagent/AGENTS.md';
let agentsCode = fs.readFileSync(agentsPath, 'utf8');

const agentRuleOld = `Use Canvas MCP tools (\`list_courses\`, \`get_assignments\`, \`get_grades\`, etc.) whenever the user asks about their courses, assignments, grades, deadlines, or anything related to their Canvas LMS account.
**WARNING**: When calling tools that require a \`courseId\`, you MUST use the exact numeric course ID (e.g. "1554114"). DO NOT use list indexes (like "1" or "2"). First, look for the numeric course ID in your conversation history. ONLY call \`list_courses\` if the ID is not available in the history.
**CRITICAL MEMORY RULE**: Because your raw tool results are NOT saved across conversation turns, whenever you use \`list_courses\` and summarize the courses for the user, you MUST include the exact numeric \`courseId\` for every course in your text response (e.g., in the markdown table). This ensures you can remember the IDs for future turns.
**CRITICAL**: Canvas is ONLY for academic course management. NEVER use Canvas tools (especially \`get_full_dump\`) for general university administrative queries such as tuition, billing, housing, dining, or financial aid. For these general topics, you MUST use \`search\` or \`web_search\` directly.`;

const agentRuleNew = `Use Canvas MCP tools (\`list_courses\`, \`get_assignments\`, \`get_grades\`, etc.) whenever the user asks about their courses, assignments, grades, deadlines, or anything related to their Canvas LMS account.
**WARNING**: When calling tools that require a \`courseId\`, you MUST use the exact numeric course ID obtained from \`list_courses\` (e.g. "1554114"). DO NOT use list indexes (like "1" or "2"). If you do not know the course ID, call \`list_courses\` first.
**CRITICAL**: Canvas is ONLY for academic course management. NEVER use Canvas tools (especially \`get_full_dump\`) for general university administrative queries such as tuition, billing, housing, dining, or financial aid. For these general topics, you MUST use \`search\` or \`web_search\` directly.`;

if (agentsCode.includes('CRITICAL MEMORY RULE')) {
  agentsCode = agentsCode.replace(agentRuleOld, agentRuleNew);
  fs.writeFileSync(agentsPath, agentsCode);
  console.log('AGENTS.md reverted');
}
