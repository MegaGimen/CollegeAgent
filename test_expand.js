import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

async function main() {
  const transport = new StdioClientTransport({
    command: '/root/.nvm/versions/node/v24.12.0/bin/node',
    args: ['/home/collegeagent/networker/MCP/server.js'],
    stderr: 'inherit'
  });
  
  const client = new Client({ name: 'test-client', version: '1.0.0' });
  await client.connect(transport);
  
  console.log('Connected. Calling expand...');
  const res = await client.callTool({
    name: 'expand',
    arguments: { url: 'https://neurotech.studentorg.berkeley.edu/' }
  });
  
  console.log(JSON.stringify(res, null, 2));
  process.exit(0);
}
main().catch(console.error);
