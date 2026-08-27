#!/usr/bin/env node
/**
 * Canvas MCP Server
 *
 * Exposes all Canvas LMS API endpoints as MCP tools via stdio transport.
 * Mirrors the REST API from server.js but as callable MCP tools.
 *
 * Usage: node mcp_server.js --canvas-token <TOKEN>
 * Connect via MCP stdio protocol.
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import Database from 'better-sqlite3';
import { writeFile, mkdir } from 'fs/promises';
import { existsSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { createHash } from 'crypto';
import TurndownService from 'turndown';
import { parseDocumentToMarkdown } from './doc_parser.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const turndownService = new TurndownService({
  headingStyle: 'atx',
  codeBlockStyle: 'fenced'
});

turndownService.addRule('removeScriptStyle', {
  filter: ['script', 'style', 'link', 'meta', 'noscript'],
  replacement: () => ''
});

turndownService.addRule('absoluteLinks', {
  filter: ['a', 'img'],
  replacement: function (content, node) {
    const isImg = node.nodeName === 'IMG';
    let rawUrl = node.getAttribute(isImg ? 'src' : 'href') || '';
    if (rawUrl && rawUrl.startsWith('/')) {
      rawUrl = 'https://bcourses.berkeley.edu' + rawUrl;
    }
    const title = node.title ? ` "${node.title}"` : '';
    return isImg ? `![${content}](${rawUrl}${title})` : `[${content}](${rawUrl}${title})`;
  }
});

turndownService.addRule('iframe', {
  filter: 'iframe',
  replacement: function (content, node) {
    const src = node.getAttribute('src');
    const title = node.getAttribute('title') || 'Embedded Media';
    if (src) {
      return `\n[📺 ${title}](${src})\n`;
    }
    return '';
  }
});

// In-memory cache for HTML -> Markdown conversion (not stored in vault)
const htmlToMdCache = new Map();

function isHtml(str) {
  if (typeof str !== 'string' || str.length < 5) return false;
  return /<\s*(?:p|div|span|h[1-6]|table|tbody|tr|td|th|ul|ol|li|a|img|br|hr|em|strong|b|i|link|script|style|iframe|blockquote)\b[^>]*>/i.test(str);
}

function convertHtmlToMarkdown(html) {
  if (!html || typeof html !== 'string') return html;
  const hash = createHash('md5').update(html).digest('hex');
  if (htmlToMdCache.has(hash)) {
    return htmlToMdCache.get(hash);
  }
  try {
    let md = turndownService.turndown(html).trim();
    md = md.replace(/\n{3,}/g, '\n\n');
    htmlToMdCache.set(hash, md);
    return md;
  } catch (e) {
    return html;
  }
}

function transformHtmlDeep(data) {
  if (data === null || data === undefined) return data;
  if (typeof data === 'string') {
    if (isHtml(data)) {
      return convertHtmlToMarkdown(data);
    }
    return data;
  }
  if (Array.isArray(data)) {
    return data.map(item => transformHtmlDeep(item));
  }
  if (typeof data === 'object') {
    const res = {};
    for (const [k, v] of Object.entries(data)) {
      res[k] = transformHtmlDeep(v);
    }
    return res;
  }
  return data;
}

// ─── Configuration ───────────────────────────────────────────────────────────
const CANVAS_BASE = 'https://bcourses.berkeley.edu/api/v1';

// Initialize SQLite Database
const db = new Database(join(__dirname, 'tokens.db'));
db.exec(`
  CREATE TABLE IF NOT EXISTS tokens (
    userId TEXT PRIMARY KEY,
    canvasToken TEXT
  )
`);

// ─── Canvas Fetch Helper (with pagination) ──────────────────────────────────

function formatWithSourceId(type, id, obj, contentField = 'content') {
  obj.sourceId = `${type}_${id}`;
  if (obj[contentField]) {
    let text = obj[contentField];
    // Simple check if it looks like HTML
    if (/<[a-z][\s\S]*>/i.test(text)) {
      text = transformHtmlDeep(text); // use existing transformer
    }
    const txtLines = text.split('\n');
    const pad = String(txtLines.length).length;
    obj[`numbered_content`] = txtLines.map((l, i) => `${String(i+1).padStart(pad, ' ')}|${l}`).join('\n');
    delete obj[contentField];
  }
  return obj;
}

async function globalCanvasFetch(token, endpoint, params = {}, options = {}) {
  const url = new URL(`${CANVAS_BASE}${endpoint}`);
  if (!options.method || options.method === 'GET') {
    url.searchParams.set('per_page', '100');
    for (const [k, v] of Object.entries(params)) {
      if (Array.isArray(v)) {
        v.forEach((val) => url.searchParams.append(k, val));
      } else if (v !== undefined && v !== null) {
        url.searchParams.set(k, v);
      }
    }
  }

  let results = [];
  let nextUrl = url.toString();

  while (nextUrl) {
    const fetchOptions = {
      ...options,
      headers: { 
        Authorization: `Bearer ${token}`,
        ...(options.headers || {})
      },
    };
    if (options.method && options.method !== 'GET' && Object.keys(params).length > 0) {
      fetchOptions.body = JSON.stringify(params);
      fetchOptions.headers['Content-Type'] = 'application/json';
    }

    const res = await fetch(nextUrl, fetchOptions);

    if (res.status === 401) {
      throw new Error(`401 Unauthorized: Canvas token expired or missing. Please ask the user for a new Canvas token and use the canvas_login tool.`);
    }
    if (!res.ok) {
      const text = await res.text();
      throw new Error(`Canvas API error ${res.status}: ${text}`);
    }

    const data = await res.json();
    if (Array.isArray(data)) {
      results = results.concat(data);
    } else {
      return data;
    }

    // Follow Link: rel="next" for pagination
    const linkHeader = res.headers.get('link');
    nextUrl = null;
    if (linkHeader) {
      const match = linkHeader.match(/<([^>]+)>;\s*rel="next"/);
      if (match) nextUrl = match[1];
    }
  }

  return results;
}

// ─── Simple Mutex for index.json writes ──────────────────────────────────
class Mutex {
  constructor() { this._promise = Promise.resolve(); }
  async acquire() {
    let release;
    const next = new Promise(resolve => release = resolve);
    const curr = this._promise;
    this._promise = this._promise.then(() => next);
    await curr;
    return release;
  }
}
const vaultMutex = new Mutex();

// ─── Background Async 1-Hop Crawler Task Queue ────────────────────────────
const activeCrawlQueue = new Set();

async function enqueueAsync1HopCrawl(userId, privateVaultDir, privateIndexPath, uniqueUrls) {
  for (const item of uniqueUrls) {
    const url = item.url;
    if (!url || activeCrawlQueue.has(url)) continue;
    activeCrawlQueue.add(url);

    (async () => {
      try {
        const { createHash } = await import('crypto');
        const urlHash = createHash('md5').update(url).digest('hex').substring(0, 16);
        const targetNodeId = `url_${urlHash}`;

        const { readFile, writeFile, mkdir } = await import('fs/promises');
        const { existsSync } = await import('fs');

        if (!existsSync(privateVaultDir)) {
          await mkdir(privateVaultDir, { recursive: true });
        }

        const pageMatch = url.match(/bcourses\.berkeley\.edu\/courses\/(\d+)\/pages\/([^\/\?]+)/);
        const fileMatch = url.match(/bcourses\.berkeley\.edu\/courses\/(\d+)\/files\/(\d+)/);

        let fetchedContent = "";
        let fetchedTitle = item.title;

        if (pageMatch) {
          const cId = pageMatch[1];
          const pId = pageMatch[2];
          try {
            let token = null;
            if (userId) {
              const row = db.prepare('SELECT canvasToken FROM tokens WHERE userId = ?').get(userId);
              if (row) token = row.canvasToken;
            }
            if (token) {
              const pData = await globalCanvasFetch(token, `/courses/${cId}/pages/${pId}`);
              const pMd = turndownService.turndown(pData.body);
              fetchedContent = `# ${pData.title}\n\n**URL**: ${url}\n\n${pMd}`;
              fetchedTitle = pData.title || fetchedTitle;
            }
          } catch (e) {
            fetchedContent = `Failed to fetch Canvas Page. HTTP ${e.message}`;
          }
        } else if (fileMatch || url.toLowerCase().split('?')[0].endsWith('.pdf')) {
          fetchedContent = "No extractable text found in this document/page (Binary/File).";
        } else {
          try {
            const res = await fetch(`http://127.0.0.1:8002/expand`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ url })
            });
            
            if (res.ok) {
              const data = await res.json();
              const release = await vaultMutex.acquire();
              try {
                let privateIndex = { nodes: {}, edges: [] };
                if (existsSync(privateIndexPath)) {
                  try { privateIndex = JSON.parse(await readFile(privateIndexPath, 'utf-8')); } catch (e) {}
                }
                privateIndex.nodes[targetNodeId] = {
                  id: targetNodeId,
                  title: data.title || item.title || 'Crawled Link',
                  url: url,
                  content: data.content || '',
                  html: data.html || ''
                };
                await writeFile(privateIndexPath, JSON.stringify(privateIndex, null, 2));
              } finally {
                release();
              }
            }
          } catch (e) {
            console.error("Playwright async crawl failed:", e);
          }
        }

        const release = await vaultMutex.acquire();
        try {
          let privateIndex = { nodes: {}, edges: [] };
          if (existsSync(privateIndexPath)) {
            try {
              privateIndex = JSON.parse(await readFile(privateIndexPath, 'utf-8'));
            } catch (e) {}
          }

          if (!privateIndex.nodes[targetNodeId]) {
            privateIndex.nodes[targetNodeId] = {
              id: targetNodeId,
              title: fetchedTitle || 'Unknown Link',
              url: url,
              content: fetchedContent
            };
          } else {
            privateIndex.nodes[targetNodeId].content = fetchedContent;
            if (fetchedTitle) privateIndex.nodes[targetNodeId].title = fetchedTitle;
          }

          const node = privateIndex.nodes[targetNodeId];
          if (!node.summary || node.summary.includes('等待 AI')) {
            fetch(`http://127.0.0.1:4090/api/tasks/register`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                id: `summary_${targetNodeId}_${Date.now()}`,
                seedUrl: `AI Summary: ${node.title}`,
                status: 'running',
                userId: userId || null
              })
            }).catch(() => {});
          }

          await writeFile(privateIndexPath, JSON.stringify(privateIndex, null, 2));
        } finally {
          release();
        }

        try {
          await fetch('http://127.0.0.1:8002/reindex?fast=true');
        } catch (e) {}
      } catch (err) {
        console.error(`Background crawl task error for ${url}:`, err);
      } finally {
        activeCrawlQueue.delete(url);
      }
    })();
  }
}

// ─── Tool Definitions ────────────────────────────────────────────────────────
const TOOLS = [
  {
    name: 'get_profile',
    description: 'Get the current user\'s Canvas profile (name, email, student ID, timezone, etc.)',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'list_courses',
    description: 'List all active courses with IDs, names, terms, and statuses (lightweight summary).',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'get_syllabus',
    description: 'Get the syllabus for a specific course. Automatically parses PDF/DOCX attachments if HTML syllabus is empty.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string', description: 'The exact numeric course ID' } },
      required: ['courseId'],
    },
  },
  {
    name: 'get_assignments',
    description: 'Get a lightweight summary list of all assignments for a course (IDs, names, due dates).',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' } },
      required: ['courseId'],
    },
  },
  {
    name: 'get_assignment_detail',
    description: 'Get full details, rubrics, and instructions for a specific assignment.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' }, assignmentId: { type: 'string' } },
      required: ['courseId', 'assignmentId'],
    },
  },
  {
    name: 'get_submissions',
    description: 'Get all submissions for the current user in a specific course.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' } },
      required: ['courseId'],
    },
  },
  {
    name: 'get_grades',
    description: 'Get current grades and enrollment details for a specific course.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' } },
      required: ['courseId'],
    },
  },
  {
    name: 'get_modules',
    description: 'Get all course modules with their items and content details.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' } },
      required: ['courseId'],
    },
  },
  {
    name: 'get_quizzes',
    description: 'Get a lightweight summary list of all quizzes for a specific course.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' } },
      required: ['courseId'],
    },
  },
  {
    name: 'get_announcements',
    description: 'Get a summary list of recent announcements for a course.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' }, limit: { type: 'number', description: 'Max items to return (default 5)' } },
      required: ['courseId'],
    },
  },
  {
    name: 'get_announcement_detail',
    description: 'Get full Markdown content and details of a specific announcement.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' }, announcementId: { type: 'string' } },
      required: ['courseId', 'announcementId'],
    },
  },
  {
    name: 'get_discussions',
    description: 'Get a summary list of discussion topics for a course.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' } },
      required: ['courseId'],
    },
  },
  {
    name: 'get_discussion_detail',
    description: 'Get full content and recent replies for a specific discussion topic.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' }, topicId: { type: 'string' } },
      required: ['courseId', 'topicId'],
    },
  },
  {
    name: 'get_files',
    description: 'Get a catalog list of files for a course (IDs, names, sizes).',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' } },
      required: ['courseId'],
    },
  },
  {
    name: 'read_file_content',
    description: 'Download and parse a file into Markdown. Supports PDF, DOCX, PPTX, XLSX, TXT, CSV. Pass courseId and fileId for Canvas files, OR pass fileUrl for web files.',
    inputSchema: {
      type: 'object',
      properties: {
        courseId: { type: 'string', description: 'Optional course ID' },
        fileId: { type: 'string', description: 'Optional Canvas file ID' },
        fileUrl: { type: 'string', description: 'Optional direct URL to the file' }
      },
      required: [],
    },
  },
  {
    name: 'get_calendar',
    description: 'Get unified calendar events.',
    inputSchema: { type: 'object', properties: { context_codes: { type: 'array', items: { type: 'string' } } }, required: [] },
  },
  {
    name: 'get_conversations',
    description: 'Get inbox conversations/messages from Canvas.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'get_activity',
    description: 'Get the user\'s recent activity stream summary.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'get_settings',
    description: 'Get the current user\'s Canvas settings.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'get_todo',
    description: 'Get upcoming TODO items for the current user.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'get_missing_submissions',
    description: 'Get assignments with missing submissions for the current user.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'get_enrollments',
    description: 'Get all enrollments (active and completed) for the current user with grades.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'get_full_dump',
    description: 'Generate a complete Markdown dump of ALL Canvas data.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'get_pages',
    description: 'Get all pages for a specific course.',
    inputSchema: {
      type: 'object',
      properties: { courseId: { type: 'string' } },
      required: ['courseId'],
    },
  },
  {
    name: 'get_page_content',
    description: 'Get the full HTML content of a specific page by its URL slug or ID, automatically cached in your private knowledge graph.',
    inputSchema: {
      type: 'object',
      properties: {
        courseId: { type: 'string' },
        urlOrId: { type: 'string' },
        userId: { type: 'string' },
        moduleId: { type: 'string' },
        itemType: { type: 'string' },
        itemId: { type: 'string' },
        previewOnly: { type: 'boolean' }
      },
      required: ['courseId', 'urlOrId'],
    },
  },
  {
    name: 'canvas_login',
    description: 'Login to Canvas using a token provided by the user.',
    inputSchema: {
      type: 'object',
      properties: { token: { type: 'string' } },
      required: ['token'],
    },
  },
];

const userCourseCache = new Map(); // sessionId -> Set<string>
const userModuleCache = new Map(); // sessionId_courseId -> Set<string>
const userPageCache = new Map(); // sessionId_courseId_moduleId -> Set<string>

const userAnnouncementCache = new Map();
const userAssignmentCache = new Map();
const userDiscussionCache = new Map();
const userFileCache = new Map();
const userQuizCache = new Map();

async function validateItem(cacheMap, cacheKey, fetchFn, itemId, itemType, courseId) {
  let validSet = cacheMap.get(cacheKey);
  if (!validSet) {
    try {
      const list = await fetchFn();
      if (Array.isArray(list)) {
        validSet = new Set(list.map(x => x.id.toString()));
        cacheMap.set(cacheKey, validSet);
      }
    } catch (e) {}
  }
  if (!validSet || !validSet.has(itemId.toString())) {
    const listPreview = validSet ? Array.from(validSet).slice(0, 20).join(', ') : 'none';
    throw new Error(`Invalid ${itemType} ID "${itemId}" for course ${courseId}. Item does not exist. Valid IDs include: [${listPreview}]. Please use list tools to verify.`);
  }
}


// ─── Create MCP Server ───────────────────────────────────────────────────────
const server = new Server(
  { name: 'canvas-mcp', version: '1.0.0' },
  { capabilities: { tools: {} } }
);

// ─── List Tools ──────────────────────────────────────────────────────────────
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS,
}));

// ─── Background Graph Builder ────────────────────────────────────────────────
const activeBuilds = new Set();
async function buildCourseGraph(userId, courseId, token) {
  const buildKey = `${userId}:${courseId}`;
  if (activeBuilds.has(buildKey)) return;
  activeBuilds.add(buildKey);

  try {
    console.error(`[Course Graph Builder] Starting build for Course ${courseId} / User ${userId}`);
    const vaultDir = `/home/collegeagent/networker/MCP/assets/private/${userId}`;
    if (!existsSync(vaultDir)) await mkdir(vaultDir, { recursive: true });

    // Fetch all pages
    
    // Fetch all modules
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
      // Fallback to /pages just in case modules don't exist
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
        // Remove trailing quotes in url if turndown left them
        let cleanUrl = url.trim().replace(/"$/, '').replace(/'$/, '');
        
        let targetFilename = urlToFilename.get(cleanUrl);
        if (!targetFilename) {
           // Try parsing URL
           try {
             const parsed = new URL(cleanUrl);
             if (parsed.host === CANVAS_HOST && parsed.pathname.includes('/pages/')) {
                // It's an internal link but maybe we didn't fetch it, skip outbound
             } else {
                outboundUrls.add(cleanUrl);
             }
           } catch (e) {
              outboundUrls.add(cleanUrl);
           }
           return match; // keep original link
        } else {
           return `[[${targetFilename}]]`;
        }
      });

      // Build MD content
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

    console.error(`[Course Graph Builder] Saved ${pages.length} pages.`);
    console.error(`[Course Graph Builder] Found ${outboundUrls.size} unique outbound links.`);

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

    // Trigger reindex
    try {
      await fetch('http://127.0.0.1:8002/reindex', { method: 'POST' });
      console.error(`[Course Graph Builder] Triggered AutoRAG reindex.`);
    } catch (err) {
      console.error(`[Course Graph Builder] Failed to trigger reindex: ${err.message}`);
    }

  } catch (err) {
    console.error(`[Course Graph Builder] Error: ${err.message}`);
  } finally {
    activeBuilds.delete(buildKey);
  }
}

// ─── Call Tool Handler ───────────────────────────────────────────────────────
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const userId = args?.userId;

  const ok = (data) => ({
    content: [{ type: 'text', text: JSON.stringify(transformHtmlDeep(data), null, 2) }],
  });
  const err = (msg) => ({
    content: [{ type: 'text', text: JSON.stringify({ error: msg }) }],
    isError: true,
  });

  try {
    if (name === 'canvas_login') {
      if (!userId) return err('userId is required, but it should be automatically injected.');
      if (!args.token) return err('token is required');
      db.prepare('INSERT OR REPLACE INTO tokens (userId, canvasToken) VALUES (?, ?)').run(userId, args.token);
      return ok({ success: true, message: 'Successfully logged into Canvas. You can now use other Canvas tools.' });
    }

    let token = null;
    if (userId) {
      const row = db.prepare('SELECT canvasToken FROM tokens WHERE userId = ?').get(userId);
      if (row) token = row.canvasToken;
    }

    if (!token) {
      return err('Canvas token expired or missing. Please ask the user for a new Canvas token and use the canvas_login tool.');
    }

    function canvasFetch(endpoint, params = {}, options = {}) {
      return globalCanvasFetch(token, endpoint, params, options);
    }

    if (args.courseId) {
      const cacheKey = args.sessionId || userId;
      let validIds = userCourseCache.get(cacheKey);
      
      // If cache is empty for this session, silently auto-fetch the course list to populate it
      if (!validIds) {
        try {
          const data = await canvasFetch('/courses', { 'enrollment_state': 'active' });
          if (Array.isArray(data)) {
            validIds = new Set(data.map(c => c.id.toString()));
            userCourseCache.set(cacheKey, validIds);
          }
        } catch (e) {
          // ignore fetch errors, let the subsequent check handle it
        }
      }

      if (!validIds) {
        return err('Failed to validate course ID. Could not fetch active courses from Canvas.');
      }

      if (!validIds.has(args.courseId.toString())) {
        const validList = Array.from(validIds).join(', ');
        return err(`Invalid courseId "${args.courseId}". This course ID was not found in your active courses. DO NOT use list indexes like "1" or "2". You MUST use the exact numeric course ID. Valid active course IDs are: ${validList}.`);
      }
    }

    switch (name) {
      // ── Profile ──────────────────────────────────────────────────────────
      case 'get_profile': {
        const data = await canvasFetch('/users/self/profile');
        return ok(data);
      }

      // ── Courses ──────────────────────────────────────────────────────────
      case 'list_courses': {
        const data = await canvasFetch('/courses', { 'enrollment_state': 'active' });
        if (Array.isArray(data)) {
          const validIds = new Set(data.map(c => c.id.toString()));
          const cacheKey = args.sessionId || userId;
          userCourseCache.set(cacheKey, validIds);
          
          const lightweight = data.map(c => ({
            id: c.id,
            name: c.name,
            course_code: c.course_code,
            term: c.term?.name || null,
            enrollment_type: (c.enrollments && c.enrollments.length > 0) ? c.enrollments[0].type : null,
            workflow_state: c.workflow_state
          }));
          return ok(lightweight);
        }
        return ok(data);
      }

      // ── Assignments ──────────────────────────────────────────────────────
      case 'get_assignments': {
        if (!args.courseId) return err('courseId is required');
        const data = await canvasFetch(`/courses/${args.courseId}/assignments`, {
          'order_by': 'due_at',
        });
        if (Array.isArray(data)) {
          const cacheKey = `${args.sessionId || userId}_${args.courseId}`;
          userAssignmentCache.set(cacheKey, new Set(data.map(x => x.id.toString())));
          
          const lightweight = data.map(x => ({
            id: x.id,
            name: x.name,
            due_at: x.due_at,
            points_possible: x.points_possible,
            submission_types: x.submission_types,
            has_submitted: x.has_submitted_submissions
          }));
          return ok(lightweight);
        }
        return ok(data);
      }

      // ── Submissions ──────────────────────────────────────────────────────
      case 'get_submissions': {
        if (!args.courseId) return err('courseId is required');
        const data = await canvasFetch(`/courses/${args.courseId}/students/submissions`, {
          'student_ids[]': ['self'],
          'include[]': ['assignment', 'visibility'],
          'order': 'graded_at',
        });
        return ok(data);
      }

      // ── Grades ───────────────────────────────────────────────────────────
      case 'get_grades': {
        if (!args.courseId) return err('courseId is required');
        const data = await canvasFetch(`/courses/${args.courseId}/enrollments`, {
          'user_id': 'self',
          'include[]': ['total_scores', 'current_points'],
        });
        return ok(data);
      }

      // ── Modules ──────────────────────────────────────────────────────────
      case 'get_modules': {
        if (!args.courseId) return err('courseId is required');
        // Non-blocking trigger for background graph builder
        if (userId && token) {
          buildCourseGraph(userId, args.courseId, token).catch(console.error);
        }
        const data = await canvasFetch(`/courses/${args.courseId}/modules`, {
          'include[]': ['items', 'content_details'],
        });
        if (Array.isArray(data)) {
          const cacheKey = args.sessionId || userId;
          const validModules = new Set(data.map(m => m.id.toString()));
          userModuleCache.set(`${cacheKey}_${args.courseId}`, validModules);
          data.forEach(m => {
            if (m.items && Array.isArray(m.items)) {
              const validPages = new Set(m.items.filter(i => i.type === 'Page' && i.page_url).map(i => i.page_url));
              userPageCache.set(`${cacheKey}_${args.courseId}_${m.id}`, validPages);
            }
          });
        }
        return ok(data);
      }

      // ── Quizzes ──────────────────────────────────────────────────────────
      case 'get_quizzes': {
        if (!args.courseId) return err('courseId is required');
        const data = await canvasFetch(`/courses/${args.courseId}/quizzes`);
        if (Array.isArray(data)) {
          const cacheKey = `${args.sessionId || userId}_${args.courseId}`;
          userQuizCache.set(cacheKey, new Set(data.map(x => x.id.toString())));
          
          const lightweight = data.map(x => ({
            id: x.id,
            title: x.title,
            due_at: x.due_at,
            time_limit: x.time_limit,
            points_possible: x.points_possible,
            question_count: x.question_count,
            html_url: x.html_url
          }));
          return ok(lightweight);
        }
        return ok(data);
      }

      // ── Announcements ────────────────────────────────────────────────────
      case 'get_announcements': {
        if (!args.courseId) return err('courseId is required');
        const limit = args.limit || 5;
        const data = await canvasFetch('/announcements', {
          'context_codes[]': [`course_${args.courseId}`],
          'per_page': limit.toString()
        });
        
        if (Array.isArray(data)) {
          const cacheKey = `${args.sessionId || userId}_${args.courseId}`;
          userAnnouncementCache.set(cacheKey, new Set(data.map(x => x.id.toString())));
          
          const lightweight = data.map(x => ({
            id: x.id,
            title: x.title,
            posted_at: x.posted_at,
            author_name: x.author ? x.author.display_name : 'Unknown',
            read_state: x.read_state,
            summary: x.message ? (typeof x.message === 'string' && x.message.length > 150 ? x.message.slice(0, 150) + '...' : x.message) : ''
          }));
          return ok(lightweight);
        }
        return ok(data);
      }

      // ── Discussions ──────────────────────────────────────────────────────
      case 'get_discussions': {
        if (!args.courseId) return err('courseId is required');
        const data = await canvasFetch(`/courses/${args.courseId}/discussion_topics`);
        if (Array.isArray(data)) {
          const cacheKey = `${args.sessionId || userId}_${args.courseId}`;
          userDiscussionCache.set(cacheKey, new Set(data.map(x => x.id.toString())));
          
          const lightweight = data.map(x => ({
            id: x.id,
            title: x.title,
            posted_at: x.posted_at,
            user_name: x.user_name,
            discussion_subentry_count: x.discussion_subentry_count,
            unread_count: x.unread_count
          }));
          return ok(lightweight);
        }
        return ok(data);
      }

      // ── Files ────────────────────────────────────────────────────────────
      case 'get_files': {
        if (!args.courseId) return err('courseId is required');
        const data = await canvasFetch(`/courses/${args.courseId}/files`, { sort: 'updated_at', order: 'desc' });
        if (Array.isArray(data)) {
          const cacheKey = `${args.sessionId || userId}_${args.courseId}`;
          userFileCache.set(cacheKey, new Set(data.map(x => x.id.toString())));
          
          const lightweight = data.map(x => ({
            id: x.id,
            display_name: x.display_name,
            size: x.size,
            created_at: x.created_at,
            updated_at: x.updated_at,
            mime_class: x.mime_class
          }));
          return ok(lightweight);
        }
        return ok(data);
      }

      // ── Calendar ─────────────────────────────────────────────────────────
      case 'get_calendar': {
        const now = new Date().toISOString();
        const future = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();
        
        let codes = args.context_codes;
        if (!codes || codes.length === 0) {
          const courses = await canvasFetch('/courses', { 'enrollment_state': 'active' });
          codes = courses.map(c => `course_${c.id}`);
        }

        const baseParams = {
          'start_date': now,
          'end_date': future,
          'context_codes[]': codes
        };

        const [events, assignments] = await Promise.all([
          canvasFetch('/calendar_events', { ...baseParams, 'type': 'event' }),
          canvasFetch('/calendar_events', { ...baseParams, 'type': 'assignment' })
        ]);

        let unified = [...events, ...assignments];
        unified.sort((a, b) => {
          const tA = new Date(a.start_at || a.all_day_date || a.created_at).getTime();
          const tB = new Date(b.start_at || b.all_day_date || b.created_at).getTime();
          return tA - tB;
        });

        return ok(unified);
      }

      // ── Conversations ────────────────────────────────────────────────────
      case 'get_conversations': {
        const data = await canvasFetch('/conversations', { 'scope': 'inbox' });
        return ok(data);
      }

      // ── Activity ─────────────────────────────────────────────────────────
      case 'get_activity': {
        const data = await canvasFetch('/users/self/activity_stream');
        if (Array.isArray(data)) {
          const lightweight = data.map(x => ({
            id: x.id,
            title: x.title,
            type: x.type,
            course_name: x.course_id ? `Course ${x.course_id}` : null,
            created_at: x.created_at,
            summary: x.message ? (typeof x.message === 'string' && x.message.length > 150 ? x.message.slice(0, 150) + '...' : x.message) : null
          }));
          return ok(lightweight);
        }
        return ok(data);
      }

      // ── Settings ─────────────────────────────────────────────────────────
      case 'get_settings': {
        const data = await canvasFetch('/users/self/settings');
        return ok(data);
      }

      // ── Todo ─────────────────────────────────────────────────────────────
      case 'get_todo': {
        const data = await canvasFetch('/users/self/todo');
        return ok(data);
      }

      // ── Missing Submissions ──────────────────────────────────────────────
      case 'get_missing_submissions': {
        const data = await canvasFetch('/users/self/missing_submissions', {
          'include[]': ['planner_overrides', 'course'],
        });
        return ok(data);
      }

      // ── Enrollments ──────────────────────────────────────────────────────
      case 'get_enrollments': {
        const data = await canvasFetch('/users/self/enrollments', {
          'include[]': ['total_scores', 'current_points', 'override_grade'],
          'state[]': ['active', 'completed'],
        });
        return ok(data);
      }

      // ── Pages ────────────────────────────────────────────────────────────
      case 'get_pages': {
        if (!args.courseId) return err('courseId is required');
        const data = await canvasFetch(`/courses/${args.courseId}/pages`);
        return ok(data);
      }

      case 'get_page_content': {
        const courseId = args.courseId;
        const moduleId = args.moduleId;
        const pageId = args.urlOrId || args.pageId;
        const userId = args.userId;
        
        if (!userId) {
          return { content: [{ type: 'text', text: JSON.stringify({ error: 'userId is required for Graph RAG' }) }], isError: true };
        }

        const cacheKey = args.sessionId || userId;
        
        // Anti-hallucination check
        if (userCourseCache.has(cacheKey) && !userCourseCache.get(cacheKey).has(courseId.toString())) {
          return { content: [{ type: 'text', text: JSON.stringify({ error: 'Course not found in current context.', available_courses: Array.from(userCourseCache.get(cacheKey)) }) }], isError: true };
        }
        
        const moduleCacheKey = `${cacheKey}_${courseId}`;
        if (moduleId && userModuleCache.has(moduleCacheKey) && !userModuleCache.get(moduleCacheKey).has(moduleId.toString())) {
          return { content: [{ type: 'text', text: JSON.stringify({ error: 'Module not found in current context.', available_modules: Array.from(userModuleCache.get(moduleCacheKey)) }) }], isError: true };
        }
        
        if (moduleId && (!args.itemType || args.itemType === 'Page')) {
          const pageCacheKey = `${cacheKey}_${courseId}_${moduleId}`;
          if (userPageCache.has(pageCacheKey) && !userPageCache.get(pageCacheKey).has(pageId.toString())) {
            return { content: [{ type: 'text', text: JSON.stringify({ error: 'Page not found in current context.', available_pages: Array.from(userPageCache.get(pageCacheKey)) }) }], isError: true };
          }
        }


        let privateVaultDir = '';
        let privateIndexPath = '';
        let privateIndex = { nodes: {}, edges: [] };
        let nodeId = `${courseId}_${moduleId}_${pageId}`;
        
        try {
           const { join, dirname } = await import('path');
           const { fileURLToPath } = await import('url');
           const { readFile, mkdir, writeFile } = await import('fs/promises');
           const { existsSync } = await import('fs');
           const __dirname_mcp = dirname(fileURLToPath(import.meta.url));
           privateVaultDir = join(__dirname_mcp, '../networker/MCP/private_vaults', userId);
           privateIndexPath = join(privateVaultDir, 'index.json');
           
           if (!existsSync(privateVaultDir)) {
             await mkdir(privateVaultDir, { recursive: true });
           }
           
           let release;
           try {
             release = await vaultMutex.acquire();
             if (existsSync(privateIndexPath)) {
               privateIndex = JSON.parse(await readFile(privateIndexPath, 'utf-8'));
             }
           } finally {
             if (release) release();
           }
           
           let cached = false;
           let outboundLinks = [];
           let data_title = pageId;
           const { createHash } = await import('crypto');

           if (privateIndex.nodes[nodeId] && privateIndex.nodes[nodeId].content) {
             cached = true;
             data_title = privateIndex.nodes[nodeId].title || pageId;
             outboundLinks = privateIndex.edges
               .filter(e => e.source === nodeId)
               .map(e => {
                 const target = privateIndex.nodes[e.target];
                 return { nodeId: e.target, url: target?.url, title: target?.title };
               });
           } else {
             // Fetch main page
             let data;
             if (args.itemType && args.itemType !== 'Page' && args.itemId) {
               const item = await canvasFetch(`/courses/${courseId}/modules/${moduleId}/items/${args.itemId}`);
               if (args.itemType === 'SubHeader') {
                 data = { title: item.title, body: `<h1>${item.title}</h1>` };
               } else if (args.itemType === 'ExternalUrl') {
                 data = { title: item.title, body: `<h2>External Resource: ${item.title}</h2>\n<p><a href="${item.external_url}">${item.external_url}</a></p>` };
               } else if (item.url) {
                 const endpoint = item.url.replace(/^https?:\/\/[^\/]+\/api\/v1/, '');
                 data = await canvasFetch(endpoint);
                 if (!data.body && data.description) data.body = data.description;
                 if (!data.title && item.title) data.title = item.title;
                 if (!data.body) data.body = `<p>No content available for this ${args.itemType}.</p>`;
               } else {
                 data = { title: item.title, body: `<pre>${JSON.stringify(item, null, 2)}</pre>` };
               }
              } else {
                data = await canvasFetch(`/courses/${courseId}/pages/${pageId}`);
                if (data.locked_for_user || (!data.body && data.body !== '')) {
                  throw new Error(`Canvas 页面未解锁或没有内容 (locked_for_user). 请先完成前置模块任务。`);
                }
              }
              
              if (moduleId && args.itemId) {
                try {
                  await canvasFetch(`/courses/${courseId}/modules/${moduleId}/items/${args.itemId}/mark_read`, {}, { method: 'POST' });
                } catch (e) {
                  // If Canvas returns 400/401 because mark_read is not required, ignore it.
                  console.error('Failed to mark item as read (might not be required):', e.message);
                }
                // 增加 1.5秒 的异步等待时间，确保即便是并发请求也有足够间隔，让 Canvas 处理解锁逻辑
                await new Promise(resolve => setTimeout(resolve, 1500));
              }

              data_title = data.title || pageId;
             const TurndownService = (await import('turndown')).default;
             const turndownService = new TurndownService();
             turndownService.addRule('absoluteLinks', {
               filter: ['a', 'img'],
               replacement: function (content, node) {
                 const isImg = node.nodeName === 'IMG';
                 let rawUrl = node.getAttribute(isImg ? 'src' : 'href') || '';
                 if (rawUrl && rawUrl.startsWith('/')) {
                   rawUrl = 'https://bcourses.berkeley.edu' + rawUrl;
                 }
                 const title = node.title ? ` "${node.title}"` : '';
                 return isImg ? `![${content}](${rawUrl}${title})` : `[${content}](${rawUrl}${title})`;
               }
             });
             const markdown = turndownService.turndown(data.body);
             
             const regex = /\!?\[([^\]]*)\]\((https?:\/\/[^\)\s]+)(?:\s+"[^"]*")?\)/g;
             let match;
             
             const urlsToFetch = [];
           
           // Parse all links
           while ((match = regex.exec(markdown)) !== null) {
             const isImage = match[0].startsWith('!');
             const linkText = match[1];
             const url = match[2];
             
             if (!isImage) {
                urlsToFetch.push({ url, title: linkText });
             }
           }
           
           const uniqueUrls = Array.from(new Map(urlsToFetch.map(item => [item.url, item])).values());
           
           if (!args.previewOnly) {
             const release = await vaultMutex.acquire();
             try {
               if (existsSync(privateIndexPath)) {
                 privateIndex = JSON.parse(await readFile(privateIndexPath, 'utf-8'));
               }
               
               // First pass: add empty nodes and edges for ALL unique links
               for (const item of uniqueUrls) {
                 const urlHash = createHash('md5').update(item.url).digest('hex').substring(0, 16);
                 const targetNodeId = `url_${urlHash}`;
                 
                 if (!privateIndex.nodes[targetNodeId]) {
                   privateIndex.nodes[targetNodeId] = {
                     id: targetNodeId,
                     title: item.title || 'Unknown Link',
                     url: item.url,
                     content: ''
                   };
                 }
                 const edgeExists = privateIndex.edges.some(e => e.source === nodeId && e.target === targetNodeId);
                 if (!edgeExists) {
                   privateIndex.edges.push({ source: nodeId, target: targetNodeId });
                 }
                 outboundLinks.push({ nodeId: targetNodeId, url: item.url, title: item.title });
               }
               
               // Save main node
               const safeTitle = (data.title || pageId).replace(/[^a-zA-Z0-9 -]/g, '').replace(/\s+/g, '-');
               privateIndex.nodes[nodeId] = {
                 id: nodeId,
                 title: data.title || pageId,
                 path: `canvas_${courseId}_${safeTitle}.md`,
                 content: `# ${data.title || pageId}\n\n**URL**: ${data.html_url}\n\n${markdown}`,
                 html: data.body || ''
               };
               
               await writeFile(privateIndexPath, JSON.stringify(privateIndex, null, 2));
             } finally {
               release();
             }
           } else {
             // Preview only: do not persist to index.json
             for (const item of uniqueUrls) {
               const urlHash = createHash('md5').update(item.url).digest('hex').substring(0, 16);
               outboundLinks.push({ nodeId: `url_${urlHash}`, url: item.url, title: item.title });
             }
             const safeTitle = (data.title || pageId).replace(/[^a-zA-Z0-9 -]/g, '').replace(/\s+/g, '-');
             privateIndex.nodes[nodeId] = {
               id: nodeId,
               title: data.title || pageId,
               path: `canvas_${courseId}_${safeTitle}.md`,
               content: `# ${data.title || pageId}\n\n**URL**: ${data.html_url}\n\n${markdown}`,
               html: data.body || ''
             };
           }

            }
           
           const mainNode = privateIndex.nodes[nodeId];
           if (mainNode && !mainNode.summary && !args.previewOnly) {
              fetch(`http://127.0.0.1:4090/api/tasks/register`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                  id: `summary_${nodeId}_${Date.now()}`,
                  seedUrl: `AI Summary: ${mainNode.title}`,
                  status: 'running',
                  userId: userId || null
                })
              }).catch(() => {});
           }

           const neighbors = [];
           for (const link of outboundLinks) {
              const targetNode = privateIndex.nodes[link.nodeId];
              if (targetNode) {
                 let summaryText = targetNode.summary;
                 if (!summaryText) {
                    if (!args.previewOnly) {
                      fetch(`http://127.0.0.1:4090/api/tasks/register`, {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({
                          id: `summary_${link.nodeId}_${Date.now()}`,
                          seedUrl: `AI Summary: ${targetNode.title}`,
                          status: 'running',
                          userId: userId || null
                        })
                      }).catch(() => {});
                    }
                    summaryText = (targetNode.content || '').substring(0, 500);
                    if ((targetNode.content || '').length > 500) summaryText += '...';
                 }
                 
                 neighbors.push({
                   nodeId: link.nodeId,
                   title: targetNode.title,
                   sourceUrl: targetNode.url || targetNode.sourceUrl || null,
                   summary: summaryText
                 });
              } else {
                 neighbors.push({
                   nodeId: link.nodeId,
                   title: link.title,
                   sourceUrl: link.url,
                   summary: 'Preview link'
                 });
              }
           }
           
           const mainContentLines = (privateIndex.nodes[nodeId].content || '').split('\n');
           const mainPad = String(mainContentLines.length).length;
           const mainNumbered = mainContentLines.map((line, i) =>
              `${String(i + 1).padStart(mainPad, ' ')}|${line}`
           ).join('\n');

           return {
               content: [{
                 type: 'text',
                 text: JSON.stringify({
                   nodeId: nodeId,
                   title: data_title,
                   path: privateIndex.nodes[nodeId].path || '',
                   cached: cached,
                   content: mainNumbered,
                   rawContent: privateIndex.nodes[nodeId].content || '',
                   rawHtml: privateIndex.nodes[nodeId].html || '',
                   summary: privateIndex.nodes[nodeId].summary || '',
                   totalLines: mainContentLines.length,
                   neighbors: neighbors
                 }, null, 2)
               }]
           };
           
        } catch (error) {
           return {
             content: [{ type: 'text', text: JSON.stringify({ error: `Failed to get page content: ${error.message}` }) }],
             isError: true
           };
        }
      }
      // ── Full Dump ────────────────────────────────────────────────────────
      case 'get_full_dump': {
        const lines = [];
        const ts = new Date().toISOString();
        const safe = (x) => (x == null ? '—' : String(x).replace(/\|/g, '\\|'));
        const fmtDate = (s) =>
          s ? new Date(s).toLocaleString('en-US', { timeZone: 'America/Los_Angeles' }) : '—';
        const strip = (html) =>
          html ? html.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() : '';

        lines.push('# Canvas LMS Full Dump');
        lines.push(`\n> **Generated**: ${ts}  \n> **Source**: bcourses.berkeley.edu\n`);

        // Profile
        lines.push('---\n\n## User Profile\n');
        try {
          const p = await canvasFetch('/users/self/profile');
          lines.push('| Field | Value |');
          lines.push('|-------|-------|');
          lines.push(`| Name | ${safe(p.name)} |`);
          lines.push(`| Email | ${safe(p.primary_email)} |`);
          lines.push(`| Student ID | ${safe(p.login_id)} |`);
          lines.push(`| Canvas ID | ${safe(p.id)} |`);
          lines.push(`| Time Zone | ${safe(p.time_zone)} |`);
        } catch (e) {
          lines.push(`_Error: ${e.message}_`);
        }

        // Courses
        lines.push('\n---\n\n## Courses\n');
        let courses = [];
        try {
          courses = await canvasFetch('/courses', {
            'include[]': ['total_scores', 'term', 'teachers'],
            'enrollment_state': 'active',
          });
          for (const c of courses) {
            const enr = (c.enrollments || [])[0] || {};
            const grade = enr.computed_current_grade || enr.computed_final_grade || '—';
            const score = enr.computed_current_score || enr.computed_final_score;
            lines.push(`### ${c.name}`);
            lines.push(`- **Code**: ${safe(c.course_code)}`);
            lines.push(`- **ID**: ${c.id}`);
            lines.push(`- **Start**: ${fmtDate(c.start_at)}`);
            lines.push(`- **Grade**: ${grade}${score != null ? ` (${score}%)` : ''}\n`);
          }
        } catch (e) {
          lines.push(`_Error: ${e.message}_`);
        }

        // Assignments
        lines.push('---\n\n## Assignments\n');
        for (const c of courses) {
          lines.push(`### ${c.name}\n`);
          try {
            const assignments = await canvasFetch(`/courses/${c.id}/assignments`, {
              'include[]': ['submission'],
              'order_by': 'due_at',
            });
            if (!assignments.length) {
              lines.push('_No assignments._\n');
              continue;
            }
            lines.push('| # | Assignment | Due | Points | Status | Score |');
            lines.push('|---|-----------|-----|--------|--------|-------|');
            assignments.forEach((a, i) => {
              const sub = a.submission || {};
              const status = sub.submitted_at
                ? 'Submitted'
                : a.due_at && new Date(a.due_at) < new Date()
                  ? 'Missing'
                  : 'Upcoming';
              const score = sub.score != null ? `${sub.score}/${a.points_possible}` : '—';
              lines.push(
                `| ${i + 1} | ${safe(a.name)} | ${fmtDate(a.due_at)} | ${safe(a.points_possible)} | ${status} | ${score} |`
              );
            });
            lines.push('');
          } catch (e) {
            lines.push(`_Error: ${e.message}_\n`);
          }
        }

        // Grades & Enrollments
        lines.push('---\n\n## Grades & Enrollments\n');
        try {
          const enrollments = await canvasFetch('/users/self/enrollments', {
            'include[]': ['total_scores', 'current_points'],
            'state[]': ['active', 'completed'],
          });
          lines.push('| Course ID | Role | State | Grade | Score | Last Active |');
          lines.push('|-----------|------|-------|-------|-------|-------------|');
          for (const e of enrollments) {
            const g = e.grades || {};
            lines.push(
              `| ${e.course_id} | ${e.role} | ${e.enrollment_state} | ${safe(g.current_grade)} | ${g.current_score != null ? `${g.current_score}%` : '—'} | ${fmtDate(e.last_activity_at)} |`
            );
          }
        } catch (e) {
          lines.push(`_Error: ${e.message}_`);
        }

        // Modules
        lines.push('\n---\n\n## Modules\n');
        for (const c of courses) {
          lines.push(`### ${c.name}\n`);
          try {
            const modules = await canvasFetch(`/courses/${c.id}/modules`, {
              'include[]': ['items'],
            });
            if (!modules.length) {
              lines.push('_No modules._\n');
              continue;
            }
            for (const m of modules) {
              lines.push(`#### ${m.name} (${(m.items || []).length} items)`);
              (m.items || []).forEach((item) => {
                lines.push(`- [${item.type}] ${item.title}`);
              });
              lines.push('');
            }
          } catch (e) {
            lines.push(`_Error: ${e.message}_\n`);
          }
        }

        // Announcements
        lines.push('---\n\n## Announcements\n');
        for (const c of courses) {
          lines.push(`### ${c.name}\n`);
          try {
            const anns = await canvasFetch('/announcements', {
              'context_codes[]': [`course_${c.id}`],
            });
            if (!anns.length) {
              lines.push('_No announcements._\n');
              continue;
            }
            for (const a of anns) {
              lines.push(`#### ${a.title}`);
              lines.push(`- **Posted**: ${fmtDate(a.posted_at)}`);
              const msg = strip(a.message);
              if (msg) lines.push(`\n${msg.substring(0, 600)}\n`);
              lines.push('');
            }
          } catch (e) {
            lines.push(`_Error: ${e.message}_\n`);
          }
        }

        // Discussions
        lines.push('---\n\n## Discussion Topics\n');
        for (const c of courses) {
          lines.push(`### ${c.name}\n`);
          try {
            const discs = await canvasFetch(`/courses/${c.id}/discussion_topics`);
            if (!discs.length) {
              lines.push('_No discussions._\n');
              continue;
            }
            lines.push('| Title | Type | Replies | Last Reply |');
            lines.push('|-------|------|---------|------------|');
            discs.forEach((d) => {
              lines.push(
                `| ${safe(d.title)} | ${d.discussion_type || 'thread'} | ${d.discussion_subentry_count || 0} | ${fmtDate(d.last_reply_at)} |`
              );
            });
            lines.push('');
          } catch (e) {
            lines.push(`_Error: ${e.message}_\n`);
          }
        }

        // Files
        lines.push('---\n\n## Files\n');
        for (const c of courses) {
          lines.push(`### ${c.name}\n`);
          try {
            const files = await canvasFetch(`/courses/${c.id}/files`, {
              'sort': 'updated_at',
              'order': 'desc',
            });
            if (!files.length) {
              lines.push('_No files._\n');
              continue;
            }
            lines.push('| Filename | Size | Updated |');
            lines.push('|----------|------|---------|');
            files.forEach((f) => {
              const size =
                f.size > 1048576
                  ? `${(f.size / 1048576).toFixed(1)}MB`
                  : f.size > 1024
                    ? `${Math.round(f.size / 1024)}KB`
                    : `${f.size}B`;
              lines.push(`| ${safe(f.display_name)} | ${size} | ${fmtDate(f.updated_at)} |`);
            });
            lines.push('');
          } catch (e) {
            lines.push(`_Error: ${e.message}_\n`);
          }
        }

        // Activity Stream
        lines.push('---\n\n## Activity Stream\n');
        try {
          const activity = await canvasFetch('/users/self/activity_stream');
          if (!activity.length) {
            lines.push('_No recent activity._');
          } else {
            lines.push('| Type | Title | Course | Date |');
            lines.push('|------|-------|--------|------|');
            activity.forEach((a) => {
              lines.push(
                `| ${a.type} | ${safe(a.title)} | ${a.course_id || '—'} | ${fmtDate(a.updated_at || a.created_at)} |`
              );
            });
          }
        } catch (e) {
          lines.push(`_Error: ${e.message}_`);
        }

        lines.push(`\n---\n\n_Dump complete. Generated at ${ts}._\n`);
        return ok({ markdown: lines.join('\n') });
      }

      
      // ── New Detail-Tier Tools ─────────────────────────────────────────────
      case 'get_syllabus': {
        if (!args.courseId) return err('courseId is required');
        const data = await canvasFetch(`/courses/${args.courseId}`, { 'include[]': ['syllabus_body'] });
        
        let md = "";
        if (data.syllabus_body && data.syllabus_body.trim() !== '') {
          md = data.syllabus_body;
        } else {
          // Fallback: search for syllabus file
          const files = await canvasFetch(`/courses/${args.courseId}/files`, { search_term: 'syllabus' });
          if (Array.isArray(files) && files.length > 0) {
            const file = files[0];
            const fileInfo = await canvasFetch(`/courses/${args.courseId}/files/${file.id}`);
            if (fileInfo.url) {
              try {
                const { tmpdir } = await import('os');
                const { join } = await import('path');
                const { writeFile } = await import('fs/promises');
                
                const res = await fetch(fileInfo.url);
                const buffer = await res.arrayBuffer();
                const tempPath = join(tmpdir(), `canvas_file_${file.id}_${file.display_name.replace(/[^a-zA-Z0-9.-]/g, '_')}`);
                await writeFile(tempPath, Buffer.from(buffer));
                
                const extracted = await parseDocumentToMarkdown(tempPath, file.display_name);
                md = `*No HTML syllabus found. Automatically extracted from attached file: ${file.display_name}*\n\n${extracted}`;
              } catch (e) {
                md = `*Error extracting syllabus file: ${e.message}*`;
              }
            }
          }
        }
        return ok(formatWithSourceId('syllabus', args.courseId, { courseId: args.courseId, syllabus_markdown: md || '*No syllabus available*' }, 'syllabus_markdown'));
      }

      case 'get_announcement_detail': {
        if (!args.courseId || !args.announcementId) return err('courseId and announcementId are required');
        const cacheKey = `${args.sessionId || userId}_${args.courseId}`;
        
        await validateItem(userAnnouncementCache, cacheKey, () => canvasFetch('/announcements', { 'context_codes[]': [`course_${args.courseId}`], 'per_page': '50' }), args.announcementId, 'Announcement', args.courseId);
        
        const data = await canvasFetch(`/courses/${args.courseId}/discussion_topics/${args.announcementId}`);
        return ok(formatWithSourceId('announcement', args.announcementId, data, 'message'));
      }

      case 'get_assignment_detail': {
        if (!args.courseId || !args.assignmentId) return err('courseId and assignmentId are required');
        const cacheKey = `${args.sessionId || userId}_${args.courseId}`;
        
        await validateItem(userAssignmentCache, cacheKey, () => canvasFetch(`/courses/${args.courseId}/assignments`, { 'order_by': 'due_at' }), args.assignmentId, 'Assignment', args.courseId);
        
        const data = await canvasFetch(`/courses/${args.courseId}/assignments/${args.assignmentId}`, { 'include[]': ['rubric', 'submission'] });
        return ok(formatWithSourceId('assignment', args.assignmentId, data, 'description'));
      }

      case 'get_discussion_detail': {
        if (!args.courseId || !args.topicId) return err('courseId and topicId are required');
        const cacheKey = `${args.sessionId || userId}_${args.courseId}`;
        
        await validateItem(userDiscussionCache, cacheKey, () => canvasFetch(`/courses/${args.courseId}/discussion_topics`), args.topicId, 'Discussion Topic', args.courseId);
        
        const topic = await canvasFetch(`/courses/${args.courseId}/discussion_topics/${args.topicId}`);
        const replies = await canvasFetch(`/courses/${args.courseId}/discussion_topics/${args.topicId}/view`);
        return ok({ 
          sourceId: `discussion_${args.topicId}`,
          topic: formatWithSourceId('discussion', args.topicId, topic, 'message'),
          replies 
        });
      }

      case 'read_file_content': {
        let fileUrl = args.fileUrl;
        let displayName = "downloaded_file";
        let fileIdStr = args.fileId ? args.fileId.toString() : "0";
        
        if (args.courseId && args.fileId) {
          const cacheKey = `${args.sessionId || userId}_${args.courseId}`;
          await validateItem(userFileCache, cacheKey, () => canvasFetch(`/courses/${args.courseId}/files`, { sort: 'updated_at', order: 'desc' }), args.fileId, 'File', args.courseId);
          
          const fileInfo = await canvasFetch(`/courses/${args.courseId}/files/${args.fileId}`);
          fileUrl = fileInfo.url;
          displayName = fileInfo.display_name;
        }
        
        if (!fileUrl) return err('Must provide either (courseId AND fileId) OR fileUrl');
        
        try {
          const { tmpdir } = await import('os');
          const { join } = await import('path');
          const { writeFile } = await import('fs/promises');
          
          const headers = {};
          if (fileUrl.includes('bcourses.berkeley.edu') && token) {
            headers['Authorization'] = `Bearer ${token}`;
          }
          
          const res = await fetch(fileUrl, { headers });
          if (!res.ok) throw new Error(`Failed to fetch file: ${res.status} ${res.statusText}`);
          
          const buffer = await res.arrayBuffer();
          const safeName = displayName.replace(/[^a-zA-Z0-9.-]/g, '_');
          const tempPath = join(tmpdir(), `canvas_file_${fileIdStr}_${Date.now()}_${safeName}`);
          await writeFile(tempPath, Buffer.from(buffer));
          
          const markdown = await parseDocumentToMarkdown(tempPath, displayName);
          return ok(formatWithSourceId('file', fileIdStr, { title: displayName, content: markdown }, 'content'));
        } catch (e) {
          return err(`Failed to read file content: ${e.message}`);
        }
      }

      default:
        return err(`Unknown tool: ${name}`);
    }
  } catch (e) {
    return err(e.message);
  }
});

// ─── Start Server ────────────────────────────────────────────────────────────
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error('🎓 Canvas MCP server started (stdio)');
  console.error(`   Tools: ${TOOLS.map((t) => t.name).join(', ')}`);
}

main().catch((err) => {
  console.error('❌ Canvas MCP server failed:', err);
  process.exit(1);
});
