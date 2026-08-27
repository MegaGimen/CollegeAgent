import McpManager from './collegeagent/mcp_manager.js';

async function test() {
  const mcpManager = new McpManager();
  await mcpManager.start();
  
  await mcpManager.callTool('list_courses', {
    userId: '2420010e-ab11-40b5-b9df-be390b505dc5',
    sessionId: 'test_session_id'
  });
  
  const res = await mcpManager.callTool('get_syllabus', {
    courseId: '1557905',
    userId: '2420010e-ab11-40b5-b9df-be390b505dc5',
    sessionId: 'test_session_id'
  });
  console.log(res);
  process.exit(0);
}

test().catch(console.error);
