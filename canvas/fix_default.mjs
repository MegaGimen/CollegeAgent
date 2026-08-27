import fs from 'fs';

let code = fs.readFileSync('/home/collegeagent/canvas/mcp_server.js', 'utf8');

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

code = code.replace(/default:\s*return err\(`Unknown tool/g, newDetailTools + "        return err(`Unknown tool");
fs.writeFileSync('/home/collegeagent/canvas/mcp_server.js', code);
