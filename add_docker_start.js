const fs = require('fs');
const filepath = '/home/collegeagent/networker/MCP/server.js';
let code = fs.readFileSync(filepath, 'utf8');

const dockerLogic = `
import { exec } from 'child_process';
// Ensure Local Firecrawl Docker is running
console.log('Starting Local Firecrawl Docker containers...');
exec('cd /home/collegeagent/firecrawl && docker compose up -d', (err, stdout, stderr) => {
  if (err) {
    console.error('Failed to start local Firecrawl Docker:', err);
  } else {
    console.log('Local Firecrawl Docker is up.');
  }
});
`;

// Insert after imports
const insertPoint = code.indexOf('const AUTORAG_API_URL');
if (insertPoint !== -1) {
  code = code.substring(0, insertPoint) + dockerLogic + '\n' + code.substring(insertPoint);
  fs.writeFileSync(filepath, code);
  console.log("Added docker start logic.");
} else {
  console.log("Could not find insert point.");
}
