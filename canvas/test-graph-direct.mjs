import Database from 'better-sqlite3';
import TurndownService from 'turndown';
import { writeFile, mkdir } from 'fs/promises';
import { existsSync } from 'fs';
import { join } from 'path';

const turndownService = new TurndownService({ headingStyle: 'atx', codeBlockStyle: 'fenced' });
const CANVAS_BASE = 'https://bcourses.berkeley.edu';

async function globalCanvasFetch(token, endpoint, params = {}) {
  const url = new URL(`${CANVAS_BASE}/api/v1${endpoint}`);
  for (const [key, val] of Object.entries(params)) {
    if (Array.isArray(val)) {
      val.forEach(v => url.searchParams.append(key, v));
    } else {
      url.searchParams.append(key, val);
    }
  }
  url.searchParams.append('per_page', '100');

  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (!res.ok) throw new Error(`Canvas API error: ${res.status} ${res.statusText}`);
  return res.json();
}

async function buildCourseGraph(userId, courseId, token) {
  try {
    console.error(`[Course Graph Builder] Starting build for Course ${courseId} / User ${userId}`);
    const vaultDir = `/home/collegeagent/networker/MCP/assets/private/${userId}`;
    if (!existsSync(vaultDir)) await mkdir(vaultDir, { recursive: true });

    let pages = [];
    try {
      const modules = await globalCanvasFetch(token, `/courses/${courseId}/modules`, { 'include[]': ['items'] });
      if (Array.isArray(modules)) {
        for (const mod of modules) {
          if (Array.isArray(mod.items)) {
            for (const item of mod.items) {
              if (item.type === 'Page' && item.page_url) {
                pages.push({ url: item.page_url, moduleId: mod.id, pageId: item.id });
              }
            }
          }
        }
      }
    } catch (e) {
      console.error(`[Course Graph Builder] Failed to fetch modules: ${e.message}`);
    }

    if (pages.length === 0) {
      try {
        const directPages = await globalCanvasFetch(token, `/courses/${courseId}/pages`);
        if (Array.isArray(directPages)) pages = directPages;
      } catch (e) {}
    }

    if (!pages || !Array.isArray(pages)) {
      console.error(`[Course Graph Builder] No pages found or failed to fetch for Course ${courseId}`);
      return;
    }

    const pagesData = [];
    const urlToFilename = new Map();
    const CANVAS_HOST = new URL(CANVAS_BASE).host;

    for (const page of pages) {
      if (!page.url) continue;
      const detail = await globalCanvasFetch(token, `/courses/${courseId}/pages/${page.url}`);
      if (!detail) continue;
      
      const safeTitle = (detail.title || page.url).replace(/[^a-zA-Z0-9_-]/g, '_');
      const filename = `Course_${courseId}_${safeTitle}_${userId.slice(0, 8)}`;
      
      const fullUrl = `${CANVAS_BASE}/courses/${courseId}/pages/${page.url}`;
      urlToFilename.set(fullUrl, filename);
      // also map without host just in case
      urlToFilename.set(`/courses/${courseId}/pages/${page.url}`, filename);
      
      pagesData.push({ page, detail, filename, fullUrl });
    }

    const outboundUrls = new Set();

    for (const data of pagesData) {
      const { page, detail, filename, fullUrl } = data;
      let bodyText = detail.body ? turndownService.turndown(detail.body) : '';
      
      // Extract and replace links
      const linkRegex = /\[(.*?)\]\((https?:\/\/[^\)\s]+)(?:\s+"[^"]*")?\)/g;
      
      bodyText = bodyText.replace(linkRegex, (match, text, url) => {
        let cleanUrl = url.trim().replace(/"$/, '').replace(/'$/, '');
        let targetFilename = urlToFilename.get(cleanUrl);
        if (!targetFilename) {
           try {
             const parsed = new URL(cleanUrl);
             if (parsed.host === CANVAS_HOST && parsed.pathname.includes('/pages/')) {
                // internal link, missing from pages? skip
             } else {
                outboundUrls.add(cleanUrl);
             }
           } catch (e) {
              outboundUrls.add(cleanUrl);
           }
           return match;
        } else {
           return `[[${targetFilename}]]`;
        }
      });

      let mdContent = `# ${detail.title || page.title}\n\n`;
      mdContent += `- **Source URL**: ${fullUrl}\n`;
      mdContent += `- **User ID**: ${userId}\n`;
      mdContent += `- **Course ID**: ${courseId}\n`;
      if (page.moduleId) mdContent += `- **Module ID**: ${page.moduleId}\n`;
      if (page.pageId) mdContent += `- **Page ID**: ${page.pageId}\n`;
      mdContent += `- **Crawled At**: ${new Date().toISOString()}\n\n`;
      mdContent += `## Content\n\n${bodyText}\n`;
      
      await writeFile(join(vaultDir, filename + '.md'), mdContent, 'utf-8');
    }

    const filteredUrls = Array.from(outboundUrls).filter(url => {
      try {
        const u = new URL(url);
        // Exclude canvas links just in case
        if (u.host === CANVAS_HOST) return false;
        // Exclude download links or image extensions
        if (u.pathname.includes('/download') || u.pathname.match(/\.(png|jpg|jpeg|gif|pdf|docx|zip)$/i)) return false;
        return true;
      } catch(e) { return false; }
    });

    console.error(`[Course Graph Builder] Saved ${pages.length} pages. Found ${filteredUrls.length} unique filtered external links.`);

    if (filteredUrls.length > 0) {
      try {
        await fetch('http://127.0.0.1:4090/api/tasks/batch', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ 
            urls: filteredUrls, 
            vaultPath: `/home/collegeagent/networker/MCP/assets/private/${userId}`,
            userId: userId,
            courseId: courseId
          })
        });
        console.error(`[Course Graph Builder] Triggered 1-hop crawl on Networker.`);
      } catch (err) {
        console.error(`[Course Graph Builder] Failed to trigger 1-hop crawl: ${err.message}`);
      }
    }
  } catch (err) {
    console.error(`[Course Graph Builder] Failed: ${err.message}`);
  }
}

const db = new Database('/home/collegeagent/collegeagent/tokens.db');
const row = db.prepare("SELECT canvasToken FROM tokens WHERE userId='2420010e-ab11-40b5-b9df-be390b505dc5'").get();
const token = row.canvasToken;
const userId = '2420010e-ab11-40b5-b9df-be390b505dc5';
const courseId = '1555334';

buildCourseGraph(userId, courseId, token).then(() => console.log('Done')).catch(console.error);
