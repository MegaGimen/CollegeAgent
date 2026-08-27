import fs from 'fs';

let code = fs.readFileSync('/home/collegeagent/canvas/mcp_server.js', 'utf8');
const switchIdx = code.indexOf('switch (name) {');
console.log("Switch starts at:", switchIdx);

let openCount = 0;
let endIndex = -1;
for(let i = switchIdx; i < code.length; i++) {
  if (code[i] === '{') openCount++;
  if (code[i] === '}') {
    openCount--;
    if (openCount === 0) {
      endIndex = i;
      break;
    }
  }
}
console.log("Switch ends at:", endIndex);
console.log("Switch body length:", endIndex - switchIdx);
