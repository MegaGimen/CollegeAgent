import Database from 'better-sqlite3';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const db = new Database('/home/collegeagent/collegeagent/tokens.db');
const row = db.prepare("SELECT canvasToken FROM tokens WHERE userId='2420010e-ab11-40b5-b9df-be390b505dc5'").get();

if (!row) {
  console.error("No token found");
  process.exit(1);
}

async function run() {
  const transport = new StdioClientTransport({
    command: 'node',
    args: ['/home/collegeagent/canvas/mcp_server.js']
  });
  const client = new Client({ name: 'test', version: '1.0' }, { capabilities: {} });
  await client.connect(transport);
  
  console.log("Connected, triggering get_modules...");
  await client.callTool({
    name: 'get_modules',
    arguments: {
      courseId: '1555334',
      userId: '2420010e-ab11-40b5-b9df-be390b505dc5'
    }
  });
  console.log("Triggered. The background build should be running.");
  setTimeout(() => process.exit(0), 10000); // let it return
}
run().catch(console.error);
