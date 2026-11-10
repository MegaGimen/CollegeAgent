import fs from 'node:fs';
import { parseOffice } from 'officeparser';

export async function parseDocumentToMarkdown(filePath, originalName) {
  let markdown = `# ${originalName}\n\n`;
  const ext = originalName.split('.').pop().toLowerCase();
  
  try {
    if (ext === 'pdf') {
      const { PDFParse } = await import('pdf-parse');
      const dataBuffer = fs.readFileSync(filePath);
      const parser = new PDFParse({ data: dataBuffer });
      const result = await parser.getText({ pageJoiner: '\n\n---\n\n' });
      markdown += result.text;
    } else if (ext === 'pptx' || ext === 'ppt') {
      const ast = await parseOffice(filePath);
      if (ast && typeof ast.toText === 'function') {
        if (Array.isArray(ast.content) && ast.content.length > 0) {
          const getTextRecursive = (node) => {
            if (node.children && node.children.length > 0) {
              return node.children.map(getTextRecursive).filter(Boolean).join('\n');
            }
            return node.text || '';
          };
          const slidesText = ast.content.map(slide => getTextRecursive(slide).trim()).filter(Boolean);
          if (slidesText.length > 0) {
            markdown += slidesText.join('\n\n---\n\n');
          } else {
            markdown += ast.toText();
          }
        } else {
          markdown += ast.toText();
        }
      } else {
        markdown += String(ast || '');
      }
    } else if (['docx', 'xlsx', 'doc', 'xls', 'odt', 'odp', 'ods', 'rtf', 'csv'].includes(ext)) {
      const ast = await parseOffice(filePath);
      if (ast && typeof ast.toText === 'function') {
        markdown += ast.toText();
      } else {
        markdown += String(ast || '');
      }
    } else if (['txt', 'md'].includes(ext)) {
      markdown += fs.readFileSync(filePath, 'utf8');
    } else {
      markdown += `*Unsupported file type: ${ext}*`;
    }
  } catch (e) {
    markdown += `*Error parsing document: ${e.message}*`;
  }
  
  return markdown;
}

export async function parseDocumentToPagesMarkdown(filePath, originalName) {
  const ext = originalName.split('.').pop().toLowerCase();
  let pages = [];

  try {
    if (ext === 'pdf') {
      const { PDFParse } = await import('pdf-parse');
      const dataBuffer = fs.readFileSync(filePath);
      const parser = new PDFParse({ data: dataBuffer });
      const result = await parser.getText({ pageJoiner: '\n\n---\n\n' });
      pages = (result.text || '').split(/\n\s*---\s*\n/).map(p => p.trim()).filter(Boolean);
    } else if (ext === 'pptx' || ext === 'ppt') {
      const ast = await parseOffice(filePath);
      if (ast && typeof ast.toText === 'function') {
        if (Array.isArray(ast.content) && ast.content.length > 0) {
          const getTextRecursive = (node) => {
            if (node.children && node.children.length > 0) {
              return node.children.map(getTextRecursive).filter(Boolean).join('\n');
            }
            return node.text || '';
          };
          pages = ast.content.map(slide => getTextRecursive(slide).trim()).filter(Boolean);
        } else {
          pages = [ast.toText().trim()];
        }
      } else {
        pages = [String(ast || '').trim()];
      }
    } else if (['docx', 'xlsx', 'doc', 'xls', 'odt', 'odp', 'ods', 'rtf', 'csv'].includes(ext)) {
      const ast = await parseOffice(filePath);
      if (ast && typeof ast.toText === 'function') {
        pages = [ast.toText().trim()];
      } else {
        pages = [String(ast || '').trim()];
      }
    } else if (['txt', 'md'].includes(ext)) {
      pages = [fs.readFileSync(filePath, 'utf8').trim()];
    } else {
      pages = [`*Unsupported file type: ${ext}*`];
    }
  } catch (e) {
    pages = [`*Error parsing document: ${e.message}*`];
  }

  if (pages.length === 0) {
    pages = ['*Empty document*'];
  }

  let formatted = `# ${originalName}\n\n`;
  pages.forEach((pText, i) => {
    formatted += `## page ${i + 1}\n${pText}\n\n`;
  });

  return formatted.trim();
}
