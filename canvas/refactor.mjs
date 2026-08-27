import fs from 'fs';

let code = fs.readFileSync('/home/collegeagent/canvas/mcp_server.js', 'utf8');

if (!code.includes('parseDocumentToMarkdown')) {
  code = code.replace("import TurndownService from 'turndown';", "import TurndownService from 'turndown';\nimport { parseDocumentToMarkdown } from './doc_parser.js';");
}

const cachesCode = `
const userAnnouncementCache = new Map();
const userAssignmentCache = new Map();
const userDiscussionCache = new Map();
const userFileCache = new Map();
const userQuizCache = new Map();

async function validateItem(cacheMap, cacheKey, fetchFn, itemId, itemType, courseId) {
  let validSet = cacheMap.get(cacheKey);
  if (!validSet) {
    try {
      const list = await fetchFn();
      if (Array.isArray(list)) {
        validSet = new Set(list.map(x => x.id.toString()));
        cacheMap.set(cacheKey, validSet);
      }
    } catch (e) {}
  }
  if (!validSet || !validSet.has(itemId.toString())) {
    const listPreview = validSet ? Array.from(validSet).slice(0, 20).join(', ') : 'none';
    throw new Error(\`Invalid \${itemType} ID "\${itemId}" for course \${courseId}. Item does not exist. Valid IDs include: [\${listPreview}]. Please use list tools to verify.\`);
  }
}
`;

if (!code.includes('userAnnouncementCache = new Map()')) {
  code = code.replace("const userPageCache = new Map(); // sessionId_courseId_moduleId -> Set<string>", "const userPageCache = new Map(); // sessionId_courseId_moduleId -> Set<string>\n" + cachesCode);
}

const newToolsObj = `const TOOLS = [
  {
    name: 'get_profile',
    description: 'Get the current user\\'s Canvas profile (name, email, student ID, timezone, etc.)',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'list_courses',
    description: 'List all active courses with IDs, names, terms, and statuses (lightweight summary).',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'get_syllabus',
    description: 'Get the syllabus for a specific course. Automatically parses PDF/DOCX attachments if HTML syllabus is empty.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string', description: 'The exact numeric course ID' } },
      required: ['courseId'],
    },
  },
  {
    name: 'get_assignments',
    description: 'Get a lightweight summary list of all assignments for a course (IDs, names, due dates).',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' } },
      required: ['courseId'],
    },
  },
  {
    name: 'get_assignment_detail',
    description: 'Get full details, rubrics, and instructions for a specific assignment.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' }, assignmentId: { type: 'string' } },
      required: ['courseId', 'assignmentId'],
    },
  },
  {
    name: 'get_submissions',
    description: 'Get all submissions for the current user in a specific course.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' } },
      required: ['courseId'],
    },
  },
  {
    name: 'get_grades',
    description: 'Get current grades and enrollment details for a specific course.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' } },
      required: ['courseId'],
    },
  },
  {
    name: 'get_modules',
    description: 'Get all course modules with their items and content details.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' } },
      required: ['courseId'],
    },
  },
  {
    name: 'get_quizzes',
    description: 'Get a lightweight summary list of all quizzes for a specific course.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' } },
      required: ['courseId'],
    },
  },
  {
    name: 'get_announcements',
    description: 'Get a summary list of recent announcements for a course.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' }, limit: { type: 'number', description: 'Max items to return (default 5)' } },
      required: ['courseId'],
    },
  },
  {
    name: 'get_announcement_detail',
    description: 'Get full Markdown content and details of a specific announcement.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' }, announcementId: { type: 'string' } },
      required: ['courseId', 'announcementId'],
    },
  },
  {
    name: 'get_discussions',
    description: 'Get a summary list of discussion topics for a course.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' } },
      required: ['courseId'],
    },
  },
  {
    name: 'get_discussion_detail',
    description: 'Get full content and recent replies for a specific discussion topic.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' }, topicId: { type: 'string' } },
      required: ['courseId', 'topicId'],
    },
  },
  {
    name: 'get_files',
    description: 'Get a catalog list of files for a course (IDs, names, sizes).',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' } },
      required: ['courseId'],
    },
  },
  {
    name: 'read_file_content',
    description: 'Download and parse a file into Markdown. Supports PDF, DOCX, PPTX, XLSX, TXT, CSV. Pass courseId and fileId for Canvas files, OR pass fileUrl for web files.',
    inputSchema: {
      type: 'object',
      properties: {
        courseId: { type: 'string', description: 'Optional course ID' },
        fileId: { type: 'string', description: 'Optional Canvas file ID' },
        fileUrl: { type: 'string', description: 'Optional direct URL to the file' }
      },
      required: [],
    },
  },
  {
    name: 'get_calendar',
    description: 'Get unified calendar events.',
    inputSchema: { type: 'object', properties: { context_codes: { type: 'array', items: { type: 'string' } } }, required: [] },
  },
  {
    name: 'get_conversations',
    description: 'Get inbox conversations/messages from Canvas.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'get_activity',
    description: 'Get the user\\'s recent activity stream summary.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'get_settings',
    description: 'Get the current user\\'s Canvas settings.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'get_todo',
    description: 'Get upcoming TODO items for the current user.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'get_missing_submissions',
    description: 'Get assignments with missing submissions for the current user.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'get_enrollments',
    description: 'Get all enrollments (active and completed) for the current user with grades.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'get_full_dump',
    description: 'Generate a complete Markdown dump of ALL Canvas data.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'get_pages',
    description: 'Get all pages for a specific course.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' } },
      required: ['courseId'],
    },
  },
  {
    name: 'get_page_content',
    description: 'Get the full HTML content of a specific page by its URL slug or ID, automatically cached in your private knowledge graph.',
    inputSchema: {
      type: 'object',
      properties: {
        courseId: { type: 'string' },
        urlOrId: { type: 'string' },
        userId: { type: 'string' },
        moduleId: { type: 'string' },
        itemType: { type: 'string' },
        itemId: { type: 'string' },
        previewOnly: { type: 'boolean' }
      },
      required: ['courseId', 'urlOrId'],
    },
  },
  {
    name: 'canvas_login',
    description: 'Login to Canvas using a token provided by the user.',
    inputSchema: {
      type: 'object',
      properties: { token: { type: 'string' } },
      required: ['token'],
    },
  },
];`;

code = code.replace(/const TOOLS = \[[\s\S]*?^\];/m, newToolsObj);

const replacements = {
  'list_courses': `
      case 'list_courses': {
        const data = await canvasFetch('/courses', { 'enrollment_state': 'active' });
        if (Array.isArray(data)) {
          const validIds = new Set(data.map(c => c.id.toString()));
          const cacheKey = args.sessionId || userId;
          userCourseCache.set(cacheKey, validIds);
          
          const lightweight = data.map(c => ({
            id: c.id,
            name: c.name,
            course_code: c.course_code,
            term: c.term?.name || null,
            enrollment_type: (c.enrollments && c.enrollments.length > 0) ? c.enrollments[0].type : null,
            workflow_state: c.workflow_state
          }));
          return ok(lightweight);
        }
        return ok(data);
      }
`,
  'get_announcements': `
      case 'get_announcements': {
        if (!args.courseId) return err('courseId is required');
        const limit = args.limit || 5;
        const data = await canvasFetch('/announcements', {
          'context_codes[]': [\`course_\${args.courseId}\`],
          'per_page': limit.toString()
        });
        
        if (Array.isArray(data)) {
          const cacheKey = \`\${args.sessionId || userId}_\${args.courseId}\`;
          userAnnouncementCache.set(cacheKey, new Set(data.map(x => x.id.toString())));
          
          const lightweight = data.map(x => ({
            id: x.id,
            title: x.title,
            posted_at: x.posted_at,
            author_name: x.author ? x.author.display_name : 'Unknown',
            read_state: x.read_state,
            summary: x.message ? (typeof x.message === 'string' && x.message.length > 150 ? x.message.slice(0, 150) + '...' : x.message) : ''
          }));
          return ok(lightweight);
        }
        return ok(data);
      }
`,
  'get_assignments': `
      case 'get_assignments': {
        if (!args.courseId) return err('courseId is required');
        const data = await canvasFetch(\`/courses/\${args.courseId}/assignments\`, {
          'order_by': 'due_at',
        });
        if (Array.isArray(data)) {
          const cacheKey = \`\${args.sessionId || userId}_\${args.courseId}\`;
          userAssignmentCache.set(cacheKey, new Set(data.map(x => x.id.toString())));
          
          const lightweight = data.map(x => ({
            id: x.id,
            name: x.name,
            due_at: x.due_at,
            points_possible: x.points_possible,
            submission_types: x.submission_types,
            has_submitted: x.has_submitted_submissions
          }));
          return ok(lightweight);
        }
        return ok(data);
      }
`,
  'get_discussions': `
      case 'get_discussions': {
        if (!args.courseId) return err('courseId is required');
        const data = await canvasFetch(\`/courses/\${args.courseId}/discussion_topics\`);
        if (Array.isArray(data)) {
          const cacheKey = \`\${args.sessionId || userId}_\${args.courseId}\`;
          userDiscussionCache.set(cacheKey, new Set(data.map(x => x.id.toString())));
          
          const lightweight = data.map(x => ({
            id: x.id,
            title: x.title,
            posted_at: x.posted_at,
            user_name: x.user_name,
            discussion_subentry_count: x.discussion_subentry_count,
            unread_count: x.unread_count
          }));
          return ok(lightweight);
        }
        return ok(data);
      }
`,
  'get_files': `
      case 'get_files': {
        if (!args.courseId) return err('courseId is required');
        const data = await canvasFetch(\`/courses/\${args.courseId}/files\`, { sort: 'updated_at', order: 'desc' });
        if (Array.isArray(data)) {
          const cacheKey = \`\${args.sessionId || userId}_\${args.courseId}\`;
          userFileCache.set(cacheKey, new Set(data.map(x => x.id.toString())));
          
          const lightweight = data.map(x => ({
            id: x.id,
            display_name: x.display_name,
            size: x.size,
            created_at: x.created_at,
            updated_at: x.updated_at,
            mime_class: x.mime_class
          }));
          return ok(lightweight);
        }
        return ok(data);
      }
`,
  'get_activity': `
      case 'get_activity': {
        const data = await canvasFetch('/users/self/activity_stream');
        if (Array.isArray(data)) {
          const lightweight = data.map(x => ({
            id: x.id,
            title: x.title,
            type: x.type,
            course_name: x.course_id ? \`Course \${x.course_id}\` : null,
            created_at: x.created_at,
            summary: x.message ? (typeof x.message === 'string' && x.message.length > 150 ? x.message.slice(0, 150) + '...' : x.message) : null
          }));
          return ok(lightweight);
        }
        return ok(data);
      }
`,
  'get_quizzes': `
      case 'get_quizzes': {
        if (!args.courseId) return err('courseId is required');
        const data = await canvasFetch(\`/courses/\${args.courseId}/quizzes\`);
        if (Array.isArray(data)) {
          const cacheKey = \`\${args.sessionId || userId}_\${args.courseId}\`;
          userQuizCache.set(cacheKey, new Set(data.map(x => x.id.toString())));
          
          const lightweight = data.map(x => ({
            id: x.id,
            title: x.title,
            due_at: x.due_at,
            time_limit: x.time_limit,
            points_possible: x.points_possible,
            question_count: x.question_count,
            html_url: x.html_url
          }));
          return ok(lightweight);
        }
        return ok(data);
      }
`
};

for (const [name, newBody] of Object.entries(replacements)) {
  const regex = new RegExp("case '" + name + "':\\s*\\{[\\s\\S]*?return ok\\([^)]+\\);\\s*\\}", "g");
  code = code.replace(regex, newBody.trim());
}

const newDetailTools = `
      // ── New Detail-Tier Tools ─────────────────────────────────────────────
      case 'get_syllabus': {
        if (!args.courseId) return err('courseId is required');
        const data = await canvasFetch(\`/courses/\${args.courseId}\`, { 'include[]': ['syllabus_body'] });
        
        let md = "";
        if (data.syllabus_body && data.syllabus_body.trim() !== '') {
          md = data.syllabus_body;
        } else {
          // Fallback: search for syllabus file
          const files = await canvasFetch(\`/courses/\${args.courseId}/files\`, { search_term: 'syllabus' });
          if (Array.isArray(files) && files.length > 0) {
            const file = files[0];
            const fileInfo = await canvasFetch(\`/courses/\${args.courseId}/files/\${file.id}\`);
            if (fileInfo.url) {
              try {
                const { tmpdir } = await import('os');
                const { join } = await import('path');
                const { writeFile } = await import('fs/promises');
                
                const res = await fetch(fileInfo.url);
                const buffer = await res.arrayBuffer();
                const tempPath = join(tmpdir(), \`canvas_file_\${file.id}_\${file.display_name.replace(/[^a-zA-Z0-9.-]/g, '_')}\`);
                await writeFile(tempPath, Buffer.from(buffer));
                
                const extracted = await parseDocumentToMarkdown(tempPath, file.display_name);
                md = \`*No HTML syllabus found. Automatically extracted from attached file: \${file.display_name}*\\n\\n\${extracted}\`;
              } catch (e) {
                md = \`*Error extracting syllabus file: \${e.message}*\`;
              }
            }
          }
        }
        return ok({ courseId: args.courseId, syllabus_markdown: md || '*No syllabus available*' });
      }

      case 'get_announcement_detail': {
        if (!args.courseId || !args.announcementId) return err('courseId and announcementId are required');
        const cacheKey = \`\${args.sessionId || userId}_\${args.courseId}\`;
        
        await validateItem(userAnnouncementCache, cacheKey, () => canvasFetch('/announcements', { 'context_codes[]': [\`course_\${args.courseId}\`], 'per_page': '50' }), args.announcementId, 'Announcement', args.courseId);
        
        const data = await canvasFetch(\`/courses/\${args.courseId}/discussion_topics/\${args.announcementId}\`);
        return ok(data);
      }

      case 'get_assignment_detail': {
        if (!args.courseId || !args.assignmentId) return err('courseId and assignmentId are required');
        const cacheKey = \`\${args.sessionId || userId}_\${args.courseId}\`;
        
        await validateItem(userAssignmentCache, cacheKey, () => canvasFetch(\`/courses/\${args.courseId}/assignments\`, { 'order_by': 'due_at' }), args.assignmentId, 'Assignment', args.courseId);
        
        const data = await canvasFetch(\`/courses/\${args.courseId}/assignments/\${args.assignmentId}\`, { 'include[]': ['rubric', 'submission'] });
        return ok(data);
      }

      case 'get_discussion_detail': {
        if (!args.courseId || !args.topicId) return err('courseId and topicId are required');
        const cacheKey = \`\${args.sessionId || userId}_\${args.courseId}\`;
        
        await validateItem(userDiscussionCache, cacheKey, () => canvasFetch(\`/courses/\${args.courseId}/discussion_topics\`), args.topicId, 'Discussion Topic', args.courseId);
        
        const topic = await canvasFetch(\`/courses/\${args.courseId}/discussion_topics/\${args.topicId}\`);
        const replies = await canvasFetch(\`/courses/\${args.courseId}/discussion_topics/\${args.topicId}/view\`);
        return ok({ topic, replies });
      }

      case 'read_file_content': {
        let fileUrl = args.fileUrl;
        let displayName = "downloaded_file";
        let fileIdStr = args.fileId ? args.fileId.toString() : "0";
        
        if (args.courseId && args.fileId) {
          const cacheKey = \`\${args.sessionId || userId}_\${args.courseId}\`;
          await validateItem(userFileCache, cacheKey, () => canvasFetch(\`/courses/\${args.courseId}/files\`, { sort: 'updated_at', order: 'desc' }), args.fileId, 'File', args.courseId);
          
          const fileInfo = await canvasFetch(\`/courses/\${args.courseId}/files/\${args.fileId}\`);
          fileUrl = fileInfo.url;
          displayName = fileInfo.display_name;
        }
        
        if (!fileUrl) return err('Must provide either (courseId AND fileId) OR fileUrl');
        
        try {
          const { tmpdir } = await import('os');
          const { join } = await import('path');
          const { writeFile } = await import('fs/promises');
          
          const headers = {};
          if (fileUrl.includes('bcourses.berkeley.edu') && token) {
            headers['Authorization'] = \`Bearer \${token}\`;
          }
          
          const res = await fetch(fileUrl, { headers });
          if (!res.ok) throw new Error(\`Failed to fetch file: \${res.status} \${res.statusText}\`);
          
          const buffer = await res.arrayBuffer();
          const safeName = displayName.replace(/[^a-zA-Z0-9.-]/g, '_');
          const tempPath = join(tmpdir(), \`canvas_file_\${fileIdStr}_\${Date.now()}_\${safeName}\`);
          await writeFile(tempPath, Buffer.from(buffer));
          
          const markdown = await parseDocumentToMarkdown(tempPath, displayName);
          return ok({ title: displayName, content: markdown });
        } catch (e) {
          return err(\`Failed to read file content: \${e.message}\`);
        }
      }

      default:
`;

code = code.replace(/default:\s*throw new Error\('Unknown tool'\);/g, newDetailTools + "\n        throw new Error('Unknown tool');");

fs.writeFileSync('/home/collegeagent/canvas/mcp_server.js', code);
console.log("Refactoring complete.");
