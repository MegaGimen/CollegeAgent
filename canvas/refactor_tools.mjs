import fs from 'fs';

const code = fs.readFileSync('/home/collegeagent/canvas/mcp_server.js', 'utf8');

const toolsRegex = /const TOOLS = \[[\s\S]*?^\];/m;
const switchRegex = /switch \(name\) \{[\s\S]*?^\s*\}/m;

console.log("Found TOOLS:", toolsRegex.test(code));
console.log("Found switch:", switchRegex.test(code));
