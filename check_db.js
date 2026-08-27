const fs = require('fs');
const db = JSON.parse(fs.readFileSync('/home/collegeagent/collegeagent/data.json', 'utf8'));
const messages = db.messages['18504e35-8db5-4d16-89d0-369f9911485a'] || [];
const toolCalls = messages.filter(m => m.meta && m.meta.toolCalls).flatMap(m => m.meta.toolCalls).filter(tc => tc.name === 'get_page_content');
const lastTc = toolCalls[toolCalls.length - 1];
try {
  const p = JSON.parse(lastTc.result);
  console.log("Parse succeeded. Keys:", Object.keys(p));
  if (p.neighbors) console.log("Neighbors count:", p.neighbors.length);
} catch (e) {
  console.log("Parse failed:", e.message);
}
