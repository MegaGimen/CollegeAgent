import Database from 'better-sqlite3';

const CANVAS_BASE = 'https://bcourses.berkeley.edu';

async function globalCanvasFetch(token, endpoint) {
  const url = new URL(`${CANVAS_BASE}/api/v1${endpoint}`);
  console.log('Fetching', url.href);
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  console.log('Status:', res.status, res.statusText);
  if (!res.ok) {
    const text = await res.text();
    console.log('Body:', text);
  } else {
    console.log('OK!');
  }
}

const db = new Database('/home/collegeagent/collegeagent/tokens.db');
const row = db.prepare("SELECT canvasToken FROM tokens WHERE userId='2420010e-ab11-40b5-b9df-be390b505dc5'").get();
globalCanvasFetch(row.canvasToken, '/courses/1555334/pages');
