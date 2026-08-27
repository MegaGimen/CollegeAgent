import Database from 'better-sqlite3';

const CANVAS_BASE = 'https://bcourses.berkeley.edu';

async function canvasFetch(token, endpoint, query = {}) {
  const url = new URL(`${CANVAS_BASE}/api/v1${endpoint}`);
  for (const [k, v] of Object.entries(query)) {
    if (Array.isArray(v)) {
      for (const item of v) url.searchParams.append(k, item);
    } else {
      url.searchParams.append(k, v);
    }
  }
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  return res.json();
}

const db = new Database('/home/collegeagent/collegeagent/tokens.db');
const token = db.prepare("SELECT canvasToken FROM tokens WHERE userId='2420010e-ab11-40b5-b9df-be390b505dc5'").get().canvasToken;

const courses = await canvasFetch(token, '/courses?enrollment_state=active');
const codes = courses.map(c => `course_${c.id}`);
const now = new Date('2026-08-01').toISOString();
const future = new Date('2026-11-01').toISOString(); 

const res1 = await canvasFetch(token, '/calendar_events', { type: 'event', start_date: now, end_date: future, 'context_codes[]': codes });
console.log('Events:', res1.length);

const res2 = await canvasFetch(token, '/calendar_events', { type: 'assignment', start_date: now, end_date: future, 'context_codes[]': codes });
console.log('Assignments:', res2.length);

