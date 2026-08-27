const fs = require('fs');

const serverPath = '/home/collegeagent/collegeagent/server.js';
let serverCode = fs.readFileSync(serverPath, 'utf8');

// 1. Update allToolCalls.push to include id
const pushStrOld = `          // Persist tool call record
          allToolCalls.push({
            name: fnName,
            args: fnArgs,
            result: (resultForAgent || '').slice(0, 4000), // cap to avoid bloating storage
            intermediateText: streamContent && streamContent.trim() ? streamContent : null,
            duration,
          });`;
const pushStrNew = `          // Persist tool call record
          allToolCalls.push({
            id: tc.id,
            name: fnName,
            args: fnArgs,
            result: (resultForAgent || '').slice(0, 4000), // cap to avoid bloating storage
            intermediateText: streamContent && streamContent.trim() ? streamContent : null,
            duration,
          });`;

if (serverCode.includes(pushStrOld)) {
  serverCode = serverCode.replace(pushStrOld, pushStrNew);
  console.log('Patched allToolCalls.push');
} else {
  console.log('Could not find allToolCalls.push to patch (maybe already patched?)');
}

// 2. Update apiMessages history mapping
const mapStrOld = `    const apiMessages = [
      { role: 'system', content: fullSystemPrompt },
      ...history.map((m) => ({ role: m.role, content: m.text })),
    ];`;

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

if (serverCode.includes(mapStrOld)) {
  serverCode = serverCode.replace(mapStrOld, mapStrNew);
  console.log('Patched apiMessages mapping');
} else {
  console.log('Could not find apiMessages mapping to patch (maybe already patched?)');
}

fs.writeFileSync(serverPath, serverCode);
console.log('server.js updated');
