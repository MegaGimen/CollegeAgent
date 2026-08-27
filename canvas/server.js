const express = require('express');
const fetch = require('node-fetch');
const cors = require('cors');
const path = require('path');
const fs = require('fs');

const app = express();
const PORT = 4091;

const CANVAS_BASE = 'https://bcourses.berkeley.edu/api/v1';

const Database = require('better-sqlite3');
const db = new Database(path.join(__dirname, 'tokens.db'));

function getToken() {
  try {
    // For now we just get the first token, or we could pass userId
    return db.prepare('SELECT canvasToken FROM tokens LIMIT 1').get().canvasToken;
  } catch (e) {
    return '';
  }
}


app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// Generic Canvas API proxy with pagination support
async function canvasFetch(endpoint, params = {}) {
  const url = new URL(`${CANVAS_BASE}${endpoint}`);
  url.searchParams.set('per_page', '100');
  Object.entries(params).forEach(([k, v]) => {
    if (Array.isArray(v)) {
      v.forEach(val => url.searchParams.append(k, val));
    } else {
      url.searchParams.set(k, v);
    }
  });

  let results = [];
  let nextUrl = url.toString();

  while (nextUrl) {
    const res = await fetch(nextUrl, {
      headers: { 'Authorization': `Bearer ${getToken()}` }
    });

    if (!res.ok) {
      const text = await res.text();
      throw new Error(`Canvas API error ${res.status}: ${text}`);
    }

    const data = await res.json();
    if (Array.isArray(data)) {
      results = results.concat(data);
    } else {
      return data;
    }

    // Follow Link: rel="next" for pagination
    const linkHeader = res.headers.get('link');
    nextUrl = null;
    if (linkHeader) {
      const match = linkHeader.match(/<([^>]+)>;\s*rel="next"/);
      if (match) nextUrl = match[1];
    }
  }

  return results;
}

// === API ROUTES ===

// Profile
app.get('/api/profile', async (req, res) => {
  try {
    const data = await canvasFetch('/users/self/profile');
    res.json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// All courses
app.get('/api/courses', async (req, res) => {
  try {
    const data = await canvasFetch('/courses', {
      'include[]': ['total_scores', 'term', 'syllabus_body', 'public_description', 'course_image', 'teachers'],
      'enrollment_state': 'active'
    });
    res.json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Assignments for a course
app.get('/api/courses/:courseId/assignments', async (req, res) => {
  try {
    const data = await canvasFetch(`/courses/${req.params.courseId}/assignments`, {
      'include[]': ['submission', 'score_statistics'],
      'order_by': 'due_at'
    });
    res.json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Submissions for a course
app.get('/api/courses/:courseId/submissions', async (req, res) => {
  try {
    const data = await canvasFetch(`/courses/${req.params.courseId}/students/submissions`, {
      'student_ids[]': ['self'],
      'include[]': ['assignment', 'visibility'],
      'order': 'graded_at'
    });
    res.json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Grades/enrollment for a course
app.get('/api/courses/:courseId/grades', async (req, res) => {
  try {
    const data = await canvasFetch(`/courses/${req.params.courseId}/enrollments`, {
      'user_id': 'self',
      'include[]': ['total_scores', 'current_points']
    });
    res.json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Modules for a course
app.get('/api/courses/:courseId/modules', async (req, res) => {
  try {
    const data = await canvasFetch(`/courses/${req.params.courseId}/modules`, {
      'include[]': ['items', 'content_details']
    });
    res.json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Announcements for a course
app.get('/api/courses/:courseId/announcements', async (req, res) => {
  try {
    const data = await canvasFetch('/announcements', {
      'context_codes[]': [`course_${req.params.courseId}`]
    });
    res.json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Discussion topics for a course
app.get('/api/courses/:courseId/discussions', async (req, res) => {
  try {
    const data = await canvasFetch(`/courses/${req.params.courseId}/discussion_topics`);
    res.json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Files for a course
app.get('/api/courses/:courseId/files', async (req, res) => {
  try {
    const data = await canvasFetch(`/courses/${req.params.courseId}/files`, {
      'sort': 'updated_at',
      'order': 'desc'
    });
    res.json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Upcoming events/calendar
app.get('/api/calendar', async (req, res) => {
  try {
    const now = new Date().toISOString();
    const future = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();
    const data = await canvasFetch('/calendar_events', {
      'type': 'assignment',
      'start_date': now,
      'end_date': future,
      'context_codes[]': ['course_1554114', 'course_1550380']
    });
    res.json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Inbox conversations
app.get('/api/conversations', async (req, res) => {
  try {
    const data = await canvasFetch('/conversations', { 'scope': 'inbox' });
    res.json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Notifications/activity stream
app.get('/api/activity', async (req, res) => {
  try {
    const data = await canvasFetch('/users/self/activity_stream');
    res.json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// User settings
app.get('/api/settings', async (req, res) => {
  try {
    const data = await canvasFetch('/users/self/settings');
    res.json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Upcoming TODO
app.get('/api/todo', async (req, res) => {
  try {
    const data = await canvasFetch('/users/self/todo');
    res.json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Missing submissions
app.get('/api/missing', async (req, res) => {
  try {
    const data = await canvasFetch('/users/self/missing_submissions', {
      'include[]': ['planner_overrides', 'course']
    });
    res.json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// User enrollments
app.get('/api/enrollments', async (req, res) => {
  try {
    const data = await canvasFetch('/users/self/enrollments', {
      'include[]': ['total_scores', 'current_points', 'override_grade'],
      'state[]': ['active', 'completed']
    });
    res.json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});


// ============================================================
// FULL DUMP ENDPOINT
// ============================================================

app.get('/api/dump-md', async (req, res) => {
  const lines = [];
  const ts = new Date().toISOString();
  const safe = (x) => (x == null ? '\u2014' : String(x).replace(/\|/g, '\\|'));
  const fmtDate = (s) => s ? new Date(s).toLocaleString('en-US', { timeZone: 'America/Los_Angeles' }) : '\u2014';
  const strip = (html) => html ? html.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() : '';

  try {
    lines.push('# Canvas LMS Full Dump');
    lines.push('\n> **Generated**: ' + ts + '  \n> **Source**: bcourses.berkeley.edu\n');

    lines.push('---\n\n## User Profile\n');
    try {
      const p = await canvasFetch('/users/self/profile');
      lines.push('| Field | Value |');
      lines.push('|-------|-------|');
      lines.push('| Name | ' + safe(p.name) + ' |');
      lines.push('| Email | ' + safe(p.primary_email) + ' |');
      lines.push('| Student ID | ' + safe(p.login_id) + ' |');
      lines.push('| Canvas ID | ' + safe(p.id) + ' |');
      lines.push('| Time Zone | ' + safe(p.time_zone) + ' |');
    } catch (e) { lines.push('_Error: ' + e.message + '_'); }

    lines.push('\n---\n\n## Courses\n');
    let courses = [];
    try {
      courses = await canvasFetch('/courses', { 'include[]': ['total_scores', 'term', 'teachers'], 'enrollment_state': 'active' });
      for (const c of courses) {
        const enr = (c.enrollments || [])[0] || {};
        const grade = enr.computed_current_grade || enr.computed_final_grade || '\u2014';
        const score = enr.computed_current_score || enr.computed_final_score;
        lines.push('### ' + c.name);
        lines.push('- **Code**: ' + safe(c.course_code));
        lines.push('- **ID**: ' + c.id);
        lines.push('- **Start**: ' + fmtDate(c.start_at));
        lines.push('- **Grade**: ' + grade + (score != null ? ' (' + score + '%)' : '') + '\n');
      }
    } catch (e) { lines.push('_Error: ' + e.message + '_'); }

    lines.push('---\n\n## Assignments\n');
    for (const c of courses) {
      lines.push('### ' + c.name + '\n');
      try {
        const assignments = await canvasFetch('/courses/' + c.id + '/assignments', { 'include[]': ['submission'], 'order_by': 'due_at' });
        if (!assignments.length) { lines.push('_No assignments._\n'); continue; }
        lines.push('| # | Assignment | Due | Points | Status | Score |');
        lines.push('|---|-----------|-----|--------|--------|-------|');
        assignments.forEach((a, i) => {
          const sub = a.submission || {};
          const status = sub.submitted_at ? 'Submitted' : (a.due_at && new Date(a.due_at) < new Date() ? 'Missing' : 'Upcoming');
          const score = sub.score != null ? sub.score + '/' + a.points_possible : '\u2014';
          lines.push('| ' + (i+1) + ' | ' + safe(a.name) + ' | ' + fmtDate(a.due_at) + ' | ' + safe(a.points_possible) + ' | ' + status + ' | ' + score + ' |');
        });
        lines.push('');
      } catch (e) { lines.push('_Error: ' + e.message + '_\n'); }
    }

    lines.push('---\n\n## Grades & Enrollments\n');
    try {
      const enrollments = await canvasFetch('/users/self/enrollments', { 'include[]': ['total_scores', 'current_points'], 'state[]': ['active', 'completed'] });
      lines.push('| Course ID | Role | State | Grade | Score | Last Active |');
      lines.push('|-----------|------|-------|-------|-------|-------------|');
      for (const e of enrollments) {
        const g = e.grades || {};
        lines.push('| ' + e.course_id + ' | ' + e.role + ' | ' + e.enrollment_state + ' | ' + safe(g.current_grade) + ' | ' + (g.current_score != null ? g.current_score + '%' : '\u2014') + ' | ' + fmtDate(e.last_activity_at) + ' |');
      }
    } catch (e) { lines.push('_Error: ' + e.message + '_'); }

    lines.push('\n---\n\n## Modules\n');
    for (const c of courses) {
      lines.push('### ' + c.name + '\n');
      try {
        const modules = await canvasFetch('/courses/' + c.id + '/modules', { 'include[]': ['items'] });
        if (!modules.length) { lines.push('_No modules._\n'); continue; }
        for (const m of modules) {
          lines.push('#### ' + m.name + ' (' + (m.items || []).length + ' items)');
          (m.items || []).forEach(item => { lines.push('- [' + item.type + '] ' + item.title); });
          lines.push('');
        }
      } catch (e) { lines.push('_Error: ' + e.message + '_\n'); }
    }

    lines.push('---\n\n## Announcements\n');
    for (const c of courses) {
      lines.push('### ' + c.name + '\n');
      try {
        const anns = await canvasFetch('/announcements', { 'context_codes[]': ['course_' + c.id] });
        if (!anns.length) { lines.push('_No announcements._\n'); continue; }
        for (const a of anns) {
          lines.push('#### ' + a.title);
          lines.push('- **Posted**: ' + fmtDate(a.posted_at));
          const msg = strip(a.message);
          if (msg) lines.push('\n' + msg.substring(0, 600) + '\n');
          lines.push('');
        }
      } catch (e) { lines.push('_Error: ' + e.message + '_\n'); }
    }

    lines.push('---\n\n## Discussion Topics\n');
    for (const c of courses) {
      lines.push('### ' + c.name + '\n');
      try {
        const discs = await canvasFetch('/courses/' + c.id + '/discussion_topics');
        if (!discs.length) { lines.push('_No discussions._\n'); continue; }
        lines.push('| Title | Type | Replies | Last Reply |');
        lines.push('|-------|------|---------|------------|');
        discs.forEach(d => { lines.push('| ' + safe(d.title) + ' | ' + (d.discussion_type || 'thread') + ' | ' + (d.discussion_subentry_count || 0) + ' | ' + fmtDate(d.last_reply_at) + ' |'); });
        lines.push('');
      } catch (e) { lines.push('_Error: ' + e.message + '_\n'); }
    }

    lines.push('---\n\n## Files\n');
    for (const c of courses) {
      lines.push('### ' + c.name + '\n');
      try {
        const files = await canvasFetch('/courses/' + c.id + '/files', { 'sort': 'updated_at', 'order': 'desc' });
        if (!files.length) { lines.push('_No files._\n'); continue; }
        lines.push('| Filename | Size | Updated |');
        lines.push('|----------|------|---------|');
        files.forEach(f => {
          const size = f.size > 1048576 ? (f.size/1048576).toFixed(1) + 'MB' : f.size > 1024 ? Math.round(f.size/1024) + 'KB' : f.size + 'B';
          lines.push('| ' + safe(f.display_name) + ' | ' + size + ' | ' + fmtDate(f.updated_at) + ' |');
        });
        lines.push('');
      } catch (e) { lines.push('_Error: ' + e.message + '_\n'); }
    }

    lines.push('---\n\n## Activity Stream\n');
    try {
      const activity = await canvasFetch('/users/self/activity_stream');
      if (!activity.length) { lines.push('_No recent activity._'); }
      else {
        lines.push('| Type | Title | Course | Date |');
        lines.push('|------|-------|--------|------|');
        activity.forEach(a => { lines.push('| ' + a.type + ' | ' + safe(a.title) + ' | ' + (a.course_id || '\u2014') + ' | ' + fmtDate(a.updated_at || a.created_at) + ' |'); });
      }
    } catch (e) { lines.push('_Error: ' + e.message + '_'); }

    lines.push('\n---\n\n_Dump complete. Generated at ' + ts + '._\n');

    const markdown = lines.join('\n');
    const filename = 'canvas-dump-' + ts.replace(/[:.]/g, '-').substring(0, 19) + '.md';
    const dumpDir = path.join(__dirname, 'dumps');
    fs.mkdirSync(dumpDir, { recursive: true });
    fs.writeFileSync(path.join(dumpDir, filename), markdown, 'utf-8');

    res.setHeader('Content-Type', 'text/markdown; charset=utf-8');
    res.setHeader('Content-Disposition', 'attachment; filename="' + filename + '"');
    res.send(markdown);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.listen(PORT, '0.0.0.0', () => {
  console.log('================================================');
  console.log(`🎓 Canvas Dashboard running on http://0.0.0.0:${PORT}`);
  console.log('================================================');
});
