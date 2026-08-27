const fs = require('fs');
const path = require('path');

const mcpPath = '/home/collegeagent/canvas/mcp_server.js';
let mcpCode = fs.readFileSync(mcpPath, 'utf8');

// 1. Replace courseId descriptions
const oldDescRegex = /courseId:\s*\{\s*type:\s*'string'([^}]*)\}/g;
mcpCode = mcpCode.replace(oldDescRegex, "courseId: { type: 'string', description: 'The exact numeric ID of the course, obtained directly from the list_courses tool result (e.g., 1554114). DO NOT use list indexes (like 1 or 2).' }");

// 2. Add userCourseCache
if (!mcpCode.includes('const userCourseCache')) {
  mcpCode = mcpCode.replace(
    '// ─── Create MCP Server ───────────────────────────────────────────────────────',
    'const userCourseCache = new Map(); // userId -> Set<string>\n\n// ─── Create MCP Server ───────────────────────────────────────────────────────'
  );
}

// 3. Add courseId validation hook
if (!mcpCode.includes('You are hallucinating course IDs')) {
  mcpCode = mcpCode.replace(
    'switch (name) {',
    `if (args.courseId) {
      const validIds = userCourseCache.get(userId);
      if (!validIds) {
        return err('You must call list_courses first to fetch the valid course IDs before calling this tool. You are hallucinating course IDs.');
      }
      if (!validIds.has(args.courseId.toString())) {
        return err(\`Invalid courseId "\${args.courseId}". This course ID was not found in the list_courses result. DO NOT use list indexes like "1" or "2". You MUST use the exact numeric ID from list_courses (e.g. "1554114").\`);
      }
    }

    switch (name) {`
  );
}

// 4. Update list_courses to save valid IDs
if (!mcpCode.includes('userCourseCache.set(userId')) {
  mcpCode = mcpCode.replace(
    `case 'list_courses': {
        const data = await canvasFetch('/courses', {`,
    `case 'list_courses': {
        const data = await canvasFetch('/courses', {`
  ).replace(
    `        });
        return ok(data);
      }

      // ── Assignments ──────────────────────────────────────────────────────`,
    `        });
        if (Array.isArray(data)) {
          const validIds = new Set(data.map(c => c.id.toString()));
          userCourseCache.set(userId, validIds);
        }
        return ok(data);
      }

      // ── Assignments ──────────────────────────────────────────────────────`
  );
}

fs.writeFileSync(mcpPath, mcpCode);
console.log('mcp_server.js updated');

// Also update AGENTS.md
const agentsPath = '/home/collegeagent/collegeagent/AGENTS.md';
let agentsCode = fs.readFileSync(agentsPath, 'utf8');

if (!agentsCode.includes('DO NOT use list indexes')) {
  agentsCode = agentsCode.replace(
    `Use Canvas MCP tools (\`list_courses\`, \`get_assignments\`, \`get_grades\`, etc.) whenever the user asks about their courses, assignments, grades, deadlines, or anything related to their Canvas LMS account.`,
    `Use Canvas MCP tools (\`list_courses\`, \`get_assignments\`, \`get_grades\`, etc.) whenever the user asks about their courses, assignments, grades, deadlines, or anything related to their Canvas LMS account.\n**WARNING**: When calling tools that require a \`courseId\`, you MUST use the exact numeric course ID obtained from \`list_courses\` (e.g. "1554114"). DO NOT use list indexes (like "1" or "2"). If you do not know the course ID, call \`list_courses\` first.`
  );
  fs.writeFileSync(agentsPath, agentsCode);
  console.log('AGENTS.md updated');
}
