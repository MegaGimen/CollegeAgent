function parseCitations(text) {
  const citations = [];
  let idx = 0;
  const numRegex = /\[\s*(\d+)(?:\s*,\s*(\d+)(?:\s*[,\-]\s*(\d+))?)?\s*\]/g;
  let match;
  while ((match = numRegex.exec(text)) !== null) {
    const sourceId = parseInt(match[1], 10);
    const before = text.slice(Math.max(0, match.index - 300), match.index);
    let lines = null;
    if (match[2]) {
      const start = parseInt(match[2], 10);
      const end = match[3] ? parseInt(match[3], 10) : start;
      lines = { start: Math.min(start, end), end: Math.max(start, end) };
    }
    citations.push({ index: ++idx, sourceId, context: before.trim(), lines });
  }
  return citations;
}

console.log(parseCitations("Here is [49, 28-42]. And [49, 68-74, 126-127] and [193] and [90, 194-260}"));
