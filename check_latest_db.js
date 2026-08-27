const fs = require('fs');
const db = JSON.parse(fs.readFileSync('/home/collegeagent/collegeagent/data.json', 'utf8'));
const messages = db.messages['18504e35-8db5-4d16-89d0-369f9911485a'] || [];
const toolCalls = messages.filter(m => m.meta && m.meta.toolCalls).flatMap(m => m.meta.toolCalls).filter(tc => tc.name === 'get_page_content');
if (toolCalls.length > 0) {
    const lastTc = toolCalls[toolCalls.length - 1]; // This is the last one
    console.log("Last get_page_content result length:", lastTc.result.length);
    console.log("Has neighbors?", lastTc.result.includes('"neighbors"'));
    try {
        const p = JSON.parse(lastTc.result);
        console.log("Neighbors length:", p.neighbors ? p.neighbors.length : 0);
    } catch(e) {
        console.log("Parse error:", e.message);
    }
} else {
    console.log("No get_page_content found.");
}
