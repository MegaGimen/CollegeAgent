const fs = require('fs');
const file = '/home/collegeagent/collegeagent/server.js';
let content = fs.readFileSync(file, 'utf8');

// Replace the regex
content = content.replace(
  /const numRegex = \/\\\[\\s\*\(\\d\+\)\(\?:\\s\*,\\s\*\(\\d\+\)\(\?:\\s\*\[,\\-\]\\s\*\(\\d\+\)\)\?\)\?\\s\*\\\]\/g;/,
  'const numRegex = /\\[\\s*(\\d+)(?:[^\\]]*)\\s*\\]/g;'
);

// Replace the whole parseCitations function.
const newParse = `function parseCitations(text) {
  const citations = [];
  let idx = 0;

  // Compact format: [1], [2,45], [3,45,62], or [3,45-62]
  const numRegex = /\\[\\s*(\\d+)([^\\]]*)\\]/g;
  let match;
  while ((match = numRegex.exec(text)) !== null) {
    const sourceId = parseInt(match[1], 10);
    const before = text.slice(Math.max(0, match.index - 300), match.index);
    let lines = null;
    
    const extra = match[2];
    if (extra && extra.trim().length > 0) {
       const nums = [...extra.matchAll(/\\d+/g)].map(m => parseInt(m[0], 10));
       if (nums.length > 0) {
         lines = { start: Math.min(...nums), end: Math.max(...nums) };
       }
    }

    citations.push({
      index: ++idx,
      sourceId,
      title: null,
      context: before.trim(),
      lines,
    });
  }

  // Legacy format fallback
  if (citations.length === 0) {
    const legacyRegex = /\\[Source:\\s*([^\\]]+)\\]/g;
    while ((match = legacyRegex.exec(text)) !== null) {
      const before = text.slice(Math.max(0, match.index - 300), match.index);
      const raw = match[1].trim();
      let title = raw;
      let lines = null;

      const linesMatch = raw.match(/^(.*?)\\s*,\\s*(\\d+)(?:\\s*[\\-,]\\s*(\\d+))?$/);
      if (linesMatch) {
        title = linesMatch[1].trim();
        const start = parseInt(linesMatch[2], 10);
        const end = linesMatch[3] ? parseInt(linesMatch[3], 10) : start;
        lines = { start: Math.min(start, end), end: Math.max(start, end) };
      }
      citations.push({
        index: ++idx,
        sourceId: null,
        title,
        context: before.trim(),
        lines,
      });
    }
  }

  return citations;
}`;

content = content.replace(/function parseCitations\(text\) \{[\s\S]*?\n\}\n/, newParse + '\n');

// Add sourceId to resolved.push
content = content.replace(/index: c\.index,\n\s*title: c\.title \|\| `Source \$\{c\.sourceId\}`,\n\s*nodeId: null,/g, 
  'index: c.index,\n        sourceId: c.sourceId,\n        title: c.title || `Source ${c.sourceId}`,\n        nodeId: null,');

content = content.replace(/index: c\.index,\n\s*title: source\.title,\n\s*nodeId: source\.nodeId,/g,
  'index: c.index,\n      sourceId: c.sourceId,\n      title: source.title,\n      nodeId: source.nodeId,');

fs.writeFileSync(file, content);
console.log('patched server.js');
