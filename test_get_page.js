const { Client } = require("@modelcontextprotocol/sdk/client/index.js");
const { StdioClientTransport } = require("@modelcontextprotocol/sdk/client/stdio.js");
async function main() {
  const transport = new StdioClientTransport({
    command: "node",
    args: ["/home/collegeagent/canvas/mcp_server.js"]
  });
  const client = new Client({ name: "test-client", version: "1.0.0" }, { capabilities: {} });
  await client.connect(transport);
  const result = await client.callTool({
    name: "get_page_content",
    arguments: {
      courseId: "1555334",
      urlOrId: "module-3",
      userId: "2420010e-ab11-40b5-b9df-be390b505dc5",
      sessionId: "18504e35-8db5-4d16-89d0-369f9911485a"
    }
  });
  console.log(JSON.stringify(result, null, 2));
  process.exit(0);
}
main().catch(console.error);
