import TurndownService from 'turndown';
const td = new TurndownService();
export function withSourceId(type, id, obj, contentField = 'content') {
  obj.sourceId = `${type}_${id}`;
  if (obj[contentField]) {
    let text = obj[contentField];
    if (/<[a-z][\s\S]*>/i.test(text)) {
      text = td.turndown(text);
    }
    const lines = text.split('\n');
    const pad = String(lines.length).length;
    obj[`numbered_${contentField}`] = lines.map((l, i) => `${String(i+1).padStart(pad, ' ')}|${l}`).join('\n');
    delete obj[contentField];
  }
  return obj;
}
