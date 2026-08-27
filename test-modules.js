const fs = require('fs');
const db = require('better-sqlite3')('/home/collegeagent/collegeagent/memories/tokens.db');
const token = db.prepare('SELECT canvasToken FROM tokens WHERE userId = ?').get('2420010e-ab11-40b5-b9df-be390b505dc5').canvasToken;
const courseId = '30000002702376';
const fetch = require('node-fetch');
(async () => {
  const res = await fetch(`https://bcourses.berkeley.edu/api/v1/courses/${courseId}/modules?include[]=items`, {
    headers: { 'Authorization': `Bearer ${token}` }
  });
  const data = await res.json();
  const module = data.find(m => m.id === 30000014713770);
  if (module) {
    const item = module.items.find(i => i.title.includes('3.05'));
    console.log("3.05 Item:", JSON.stringify(item, null, 2));
    const item304 = module.items.find(i => i.title.includes('3.04'));
    console.log("3.04 Item:", JSON.stringify(item304, null, 2));
  }
})();
