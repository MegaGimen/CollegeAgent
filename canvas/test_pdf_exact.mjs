import fs from 'fs';

async function run() {
  const url = "https://bcourses.berkeley.edu/files/95216028/download?download_frd=1&verifier=d8e35c8f-9e16-4edc-af0f-82f300bc7bdd";
  const res = await fetch(url);
  const buffer = await res.arrayBuffer();
  fs.writeFileSync('syllabus3.pdf', Buffer.from(buffer));
  
  const mod = await import('pdf-parse');
  const pdfParse = mod.default || mod;
  
  try {
    const dataBuffer = fs.readFileSync('syllabus3.pdf');
    const result = await pdfParse(dataBuffer, { pagerender: function(pageData) { return pageData.getTextContent().then(function(textContent) { let lastY, text = ''; for (let item of textContent.items) { if (lastY == item.transform[5] || !lastY){ text += item.str; } else { text += '\n' + item.str; } lastY = item.transform[5]; } return text; }); }});
    console.log("Success! length:", result.text.length);
  } catch(e) {
    console.log("Error caught:", e.message);
  }
}
run();
