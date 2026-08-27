import fs from 'fs';
import { PDFParse } from 'pdf-parse';

async function run() {
  const url = "https://bcourses.berkeley.edu/files/95216028/download?download_frd=1&verifier=d8e35c8f-9e16-4edc-af0f-82f300bc7bdd";
  const res = await fetch(url);
  const buffer = await res.arrayBuffer();
  fs.writeFileSync('syllabus3.pdf', Buffer.from(buffer));
  
  try {
    const parser = new PDFParse({ data: Buffer.from(buffer) });
    const result = await parser.getText({ pageJoiner: '\n\n---\n\n' });
    console.log("Success! Length:", result.text.length);
  } catch(e) {
    console.log("Error inside pdf-parse:", e.message);
  }
}
run();
