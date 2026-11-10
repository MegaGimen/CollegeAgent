const fs = require('fs');
const text = fs.readFileSync('full_ai_text.txt', 'utf8');
const numRegex = /\[\s*(\d+)([^\]]*)\]/g;
let match;
let count = 0;
while ((match = numRegex.exec(text)) !== null) {
  count++;
  console.log(`Index ${count}: matched "${match[0]}"`);
}
