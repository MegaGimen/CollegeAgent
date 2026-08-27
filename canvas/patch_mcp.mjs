import fs from 'fs';
const code = fs.readFileSync('mcp_server.js', 'utf8');

const helper = `
function formatWithSourceId(type, id, obj, contentField = 'content') {
  obj.sourceId = \`\${type}_\${id}\`;
  if (obj[contentField]) {
    let text = obj[contentField];
    if (/<[a-z][\s\S]*>/i.test(text)) {
      text = new (require('turndown'))().turndown(text); // TurndownService is already imported globally
    }
    const lines = text.split('\\n');
    const pad = String(lines.length).length;
    obj[\`numbered_\${contentField}\`] = lines.map((l, i) => \`\${String(i+1).padStart(pad, ' ')}|\${l}\`).join('\\n');
    delete obj[contentField];
  }
  return obj;
}
`;

// Insert the helper at line 122 (before globalCanvasFetch)
const lines = code.split('\n');
const insertIndex = lines.findIndex(l => l.includes('function globalCanvasFetch'));
lines.splice(insertIndex, 0, `
function formatWithSourceId(type, id, obj, contentField = 'content') {
  obj.sourceId = \`\${type}_\${id}\`;
  if (obj[contentField]) {
    let text = obj[contentField];
    // Simple check if it looks like HTML
    if (/<[a-z][\\s\\S]*>/i.test(text)) {
      text = transformHtmlDeep(text); // use existing transformer
    }
    const txtLines = text.split('\\n');
    const pad = String(txtLines.length).length;
    obj[\`numbered_content\`] = txtLines.map((l, i) => \`\${String(i+1).padStart(pad, ' ')}|\${l}\`).join('\\n');
    delete obj[contentField];
  }
  return obj;
}
`);

let newCode = lines.join('\n');

// Patch get_syllabus
newCode = newCode.replace(
  `return ok({ courseId: args.courseId, syllabus_markdown: md || '*No syllabus available*' });`,
  `return ok(formatWithSourceId('syllabus', args.courseId, { courseId: args.courseId, syllabus_markdown: md || '*No syllabus available*' }, 'syllabus_markdown'));`
);

// Patch get_announcement_detail
newCode = newCode.replace(
  `const data = await canvasFetch(\`/courses/\${args.courseId}/discussion_topics/\${args.announcementId}\`);
        return ok(data);`,
  `const data = await canvasFetch(\`/courses/\${args.courseId}/discussion_topics/\${args.announcementId}\`);
        return ok(formatWithSourceId('announcement', args.announcementId, data, 'message'));`
);

// Patch get_assignment_detail
newCode = newCode.replace(
  `const data = await canvasFetch(\`/courses/\${args.courseId}/assignments/\${args.assignmentId}\`);
        return ok(data);`,
  `const data = await canvasFetch(\`/courses/\${args.courseId}/assignments/\${args.assignmentId}\`);
        return ok(formatWithSourceId('assignment', args.assignmentId, data, 'description'));`
);

// Patch get_discussion_detail
newCode = newCode.replace(
  `const topic = await canvasFetch(\`/courses/\${args.courseId}/discussion_topics/\${args.topicId}\`);
        const replies = await canvasFetch(\`/courses/\${args.courseId}/discussion_topics/\${args.topicId}/view\`);
        return ok({ topic, replies });`,
  `const topic = await canvasFetch(\`/courses/\${args.courseId}/discussion_topics/\${args.topicId}\`);
        const replies = await canvasFetch(\`/courses/\${args.courseId}/discussion_topics/\${args.topicId}/view\`);
        return ok({ 
          sourceId: \`discussion_\${args.topicId}\`,
          topic: formatWithSourceId('discussion', args.topicId, topic, 'message'),
          replies 
        });`
);

// Patch read_file_content
newCode = newCode.replace(
  `return ok({ title: displayName, content: markdown });`,
  `return ok(formatWithSourceId('file', fileIdStr, { title: displayName, content: markdown }, 'content'));`
);

fs.writeFileSync('mcp_server.js', newCode);
console.log('Patched mcp_server.js');
