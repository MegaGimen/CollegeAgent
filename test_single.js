const { spawn } = require('child_process');

const server = spawn('node', ['/home/collegeagent/canvas/mcp_server.js']);
server.stdout.on('data', data => {
  const str = data.toString();
  if (str.includes('"jsonrpc":"2.0"')) {
    require('fs').writeFileSync('/tmp/response.json', str);
    console.log("Response written to /tmp/response.json");
    process.exit(0);
  }
});
server.stderr.on('data', data => {});

const req = {
  jsonrpc: "2.0",
  id: 1,
  method: "tools/call",
  params: {
    name: "get_page_content",
    arguments: {
      courseId: "1555334",
      moduleId: "2583781",
      pageId: "bystander-intervention",
      userId: "2420010e-ab11-40b5-b9df-be390b505dc5",
      token: process.env.CANVAS_TOKEN
    }
  }
};
server.stdin.write(JSON.stringify(req) + '\n');
