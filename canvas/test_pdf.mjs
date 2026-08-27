import fs from 'fs';
import { parseDocumentToMarkdown } from './doc_parser.js';

async function run() {
  const url = "https://bcourses.berkeley.edu/files/95216028/download?download_frd=1&verifier=d8e35c8f-9e16-4edc-af0f-82f300bc7bdd";
  const res = await fetch(url);
  const buffer = await res.arrayBuffer();
  fs.writeFileSync('syllabus3.pdf', Buffer.from(buffer));
  
  const markdown = await parseDocumentToMarkdown('syllabus3.pdf', 'syllabus3.pdf');
  console.log(markdown);
}
run();
