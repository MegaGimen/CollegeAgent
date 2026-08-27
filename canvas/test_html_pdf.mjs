import fs from 'fs';
import { PDFParse } from 'pdf-parse';

async function run() {
  const buffer = Buffer.from("<html><body>Login required</body></html>");
  
  try {
    const parser = new PDFParse({ data: buffer });
    const result = await parser.getText({ pageJoiner: '\n\n---\n\n' });
    console.log("Success! Length:", result.text.length);
  } catch(e) {
    console.log("Error inside pdf-parse:", e.message);
  }
}
run();
