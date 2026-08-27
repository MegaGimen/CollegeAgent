import McpManager from './collegeagent/mcp_manager.js';

async function test() {
  const mcpManager = new McpManager();
  await mcpManager.start();
  
  console.log('Seeding cache with get_modules...');
  await mcpManager.callTool('get_modules', {
    courseId: '1555334',
    userId: '2420010e-ab11-40b5-b9df-be390b505dc5',
    sessionId: 'test_session_id'
  });
  
  const pages = ['bystander-intervention', 'consent-under-the-influence', 'alcohol-overdose-intervention'];
  
  for (const page of pages) {
    console.log(`Fetching ${page}...`);
    await mcpManager.callTool('get_page_content', {
      courseId: '1555334',
      urlOrId: page,
      userId: '2420010e-ab11-40b5-b9df-be390b505dc5',
      moduleId: '2583781',
      sessionId: 'test_session_id'
    });
  }
  
  console.log('Done!');
  process.exit(0);
}

test().catch(console.error);
