const text = "[49, 28-42]";
const numRegex = /\[\s*(\d+)(?:\s*,\s*(\d+)(?:\s*[,\-]\s*(\d+))?)?\s*\]/g;
let match;
while ((match = numRegex.exec(text)) !== null) {
  console.log(match);
}
