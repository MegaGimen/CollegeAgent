import fs from 'fs';
const code = fs.readFileSync('/home/collegeagent/canvas/mcp_server.js', 'utf8');

const targetCases = ['list_courses', 'get_announcements', 'get_assignments', 'get_discussions', 'get_files', 'get_activity', 'get_modules', 'get_quizzes'];

for (const name of targetCases) {
  const regex = new RegExp(`case '${name}':\\s*\\{[\\s\\S]*?return ok\\([^)]+\\);\\s*\\}`, 'g');
  const match = code.match(regex);
  if (match) {
    console.log(`Matched ${name}, length: ${match[0].length}`);
  } else {
    console.log(`Failed to match ${name}`);
  }
}
