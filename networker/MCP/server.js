#!/usr/bin/env node
/**
 * Networker MCP Server
 * 
 * Provides search, read, and traverse over an Obsidian-style markdown vault.
 * Search is powered by AutoRAG (auto-selects the best retrieval method).
 * 
 * Exposes 4 tools:
 *   - search: AutoRAG-powered retrieval (best of BM25/TF-IDF/Transformer)
 *   - read: Read a specific note by node ID
 *   - traverse: Get all connected nodes from a given node ID
 *   - expand: Expand the graph by reading 1-hop neighbors (no background crawl)
 *   - web_search: Live web search + synchronous 1-hop crawl, saves to vault
 * 
 * Usage: node server.js
 * 
 * Connect via MCP stdio protocol.
 * Requires: AutoRAG search API running on AUTRAG_API_URL (default http://127.0.0.1:8001)
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { readFile, writeFile, mkdir } from 'fs/promises';
import { existsSync } from 'fs';
import { join, basename } from 'path';
import { createHash } from 'crypto';

// AutoRAG Search API URL (run_api.py serves on this port)
const AUTORAG_API_URL = process.env.AUTORAG_API_URL || 'http://127.0.0.1:8002';

// Brave Search API
const BRAVE_API_KEY = process.env.BRAVE_API_KEY || 'BSAVttnxLyCj__w6OAAUs9krdnBtvUb';
const BRAVE_SEARCH_URL = 'https://api.search.brave.com/res/v1/web/search';

// Networker REST API (for triggering async crawls)
const NETWORKER_API_URL = process.env.NETWORKER_API_URL || 'http://127.0.0.1:4090';

// MCP assets directory (where crawled vault files are saved)
import { fileURLToPath } from 'url';
import { dirname } from 'path';
const __filename_mcp = fileURLToPath(import.meta.url);
const __dirname_mcp = dirname(__filename_mcp);
const MCP_ASSETS_DIR = join(__dirname_mcp, 'assets');

// ── Playwright: synchronous 1-hop crawl for web_search ──
import { chromium } from 'playwright';

/**
 * Sanitize a title for use as an Obsidian filename.
 */
function sanitizeFilename(title, url) {
  if (!title || !title.trim()) {
    try {
      const parsed = new URL(url);
      title = parsed.pathname.replace(/^\/|\/$/g, '').replace(/\//g, ' - ') || 'home';
    } catch {
      title = 'untitled';
    }
  }
  return title
    .replace(/[\\/:*?"<>|#^[\]]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .substring(0, 150);
}

/**
 * Synchronously crawl a list of URLs using Playwright.
 * Depth=1 (single page only), saves markdown to vault.
 * Returns array of { url, title, content, outboundLinks }.
 */
/**
 * Detect if a page title/content indicates bot blocking.
 * Returns { blocked: true, reason: string } or { blocked: false }.
 */
function detectBlocking(title, pageText) {
  const t = (title || '').toLowerCase();
  const txt = (pageText || '').toLowerCase().slice(0, 500);

  // Cloudflare challenge
  if (t.includes('just a moment') || t.includes('attention required')) {
    return { blocked: true, reason: 'Cloudflare challenge' };
  }
  // Generic 403/forbidden
  if (t.includes('403') || t.includes('forbidden') || t.includes('access denied')) {
    return { blocked: true, reason: 'Access denied (403)' };
  }
  // Bot detection
  if (txt.includes('don\'t smell human') || txt.includes('are you a robot') ||
      txt.includes('please verify you are human') || txt.includes('captcha')) {
    return { blocked: true, reason: 'Bot detection triggered' };
  }
  return { blocked: false };
}

async function crawlPagesSync(urls, vaultDir) {
  if (!urls || urls.length === 0) return [];

  let browser;
  const results = [];

  try {
    // Use new headless mode (harder to detect) + realistic browser settings
    browser = await chromium.launch({
      headless: true,
      args: [
        '--disable-blink-features=AutomationControlled',
        '--disable-features=IsolateOrigins,site-per-process',
      ],
    });
    const context = await browser.newContext({
      userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      viewport: { width: 1440, height: 900 },
      locale: 'en-US',
      timezoneId: 'America/Los_Angeles',
      extraHTTPHeaders: {
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
      },
    });

    // Ensure vault directory exists
    if (!existsSync(vaultDir)) {
      await mkdir(vaultDir, { recursive: true });
    }

    for (const url of urls) {
      const page = await context.newPage();
      // Block heavy resources
      await page.route('**/*', (route) => {
        const type = route.request().resourceType();
        if (['image', 'media', 'font', 'stylesheet'].includes(type)) {
          route.abort();
        } else {
          route.continue();
        }
      });

      try {
        await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 20000 });

        // Handle WAF challenges — wait for Cloudflare / other challenges to resolve
        let rawTitle = await page.title();
        const challengePatterns = ['Client Challenge', 'Just a moment', 'Attention Required'];
        const isChallenge = challengePatterns.some(p => rawTitle.includes(p));
        if (isChallenge) {
          console.error(`  \u{23F3} Challenge detected for ${url}: "${rawTitle}", waiting up to 15s...`);
          for (let attempt = 0; attempt < 15; attempt++) {
            await page.waitForTimeout(1000);
            rawTitle = await page.title();
            const stillChallenge = challengePatterns.some(p => rawTitle.includes(p));
            if (!stillChallenge && rawTitle) {
              console.error(`  \u{2705} Challenge solved after ${attempt + 1}s`);
              break;
            }
          }
        }

        // Check if page is still blocked after waiting
        const bodyText = await page.evaluate(() => document.body?.innerText?.slice(0, 500) || '');
        const blockCheck = detectBlocking(rawTitle, bodyText);
        if (blockCheck.blocked) {
          console.error(`  \u{1F6AB} Blocked: ${url} — ${blockCheck.reason}`);
          results.push({
            url,
            title: rawTitle || 'Blocked',
            content: `[BLOCKED] This page could not be crawled: ${blockCheck.reason}. The site may use Cloudflare, CDN protection, or bot detection. Use web_search snippets for this URL instead.`,
            totalLines: 1,
            outboundLinks: [],
            crawlBlocked: true,
            blockReason: blockCheck.reason,
          });
          await page.close().catch(() => {});
          continue;
        }

        const cleanTitle = sanitizeFilename(rawTitle, url);

        // Extract main content as markdown via DOM walker
        const pageMarkdown = await page.evaluate(() => {
          const selectors = ['main', 'article', '#content', '#main', '.content', '.main'];
          let root = null;
          for (const sel of selectors) {
            root = document.querySelector(sel);
            if (root) break;
          }
          if (!root) root = document.body;

          function toMarkdown(node) {
            if (!node) return '';
            const ignoreTags = ['SCRIPT', 'STYLE', 'NAV', 'HEADER', 'FOOTER', 'IFRAME', 'NOSCRIPT', 'SVG', 'FORM', 'INPUT', 'BUTTON'];
            if (ignoreTags.includes(node.tagName)) return '';
            if (node.nodeType === Node.TEXT_NODE) return node.nodeValue.replace(/\s+/g, ' ');
            if (node.nodeType !== Node.ELEMENT_NODE) return '';
            const childrenMarkdown = Array.from(node.childNodes).map(child => toMarkdown(child)).join('');
            const tag = node.tagName;
            switch (tag) {
              case 'H1': return `\n# ${childrenMarkdown.trim()}\n`;
              case 'H2': return `\n## ${childrenMarkdown.trim()}\n`;
              case 'H3': return `\n### ${childrenMarkdown.trim()}\n`;
              case 'H4': return `\n#### ${childrenMarkdown.trim()}\n`;
              case 'H5': return `\n##### ${childrenMarkdown.trim()}\n`;
              case 'H6': return `\n###### ${childrenMarkdown.trim()}\n`;
              case 'P': return `\n${childrenMarkdown.trim()}\n`;
              case 'BR': return `\n`;
              case 'STRONG': case 'B': return `**${childrenMarkdown.trim()}**`;
              case 'EM': case 'I': return `*${childrenMarkdown.trim()}*`;
              case 'LI': return `\n- ${childrenMarkdown.trim()}`;
              case 'UL': return `\n${childrenMarkdown.trim()}\n`;
              case 'OL': return `\n${childrenMarkdown.trim()}\n`;
              case 'A': {
                const href = node.getAttribute('href');
                const text = childrenMarkdown.trim();
                if (!text) return '';
                try {
                  const absUrl = new URL(href, window.location.href);
                  const isImg = /\.(png|jpg|jpeg|gif|svg)$/i.test(absUrl.pathname);
                  if (isImg) return `![${text}](${absUrl.toString()})`;
                } catch {}
                return href ? `[${text}](${href})` : text;
              }
              case 'IMG': {
                const src = node.getAttribute('src');
                const alt = node.getAttribute('alt') || '';
                if (!src) return '';
                try { return `![${alt}](${new URL(src, window.location.href).toString()})`; }
                catch { return `![${alt}](${src})`; }
              }
              default: return childrenMarkdown;
            }
          }
          return toMarkdown(root).replace(/\n{3,}/g, '\n\n').trim();
        });

        // Extract outbound links (1-hop)
        const outboundLinks = await page.evaluate(() => {
          return Array.from(document.querySelectorAll('a'))
            .map(a => ({
              href: a.href,
              text: (a.innerText || a.getAttribute('title') || '').trim(),
            }))
            .filter(item => item.href)
            .map(item => {
              try {
                const absUrl = new URL(item.href, window.location.href);
                if (absUrl.protocol === 'http:' || absUrl.protocol === 'https:') {
                  return { url: absUrl.toString(), title: item.text };
                }
              } catch {}
              return null;
            })
            .filter(Boolean)
            .filter((v, i, arr) => arr.findIndex(x => x.url === v.url) === i);
        });

        // Build Obsidian-style markdown file
        let mdContent = `# ${cleanTitle}\n\n`;
        mdContent += `- **Source URL**: [${url}](${url})\n`;
        mdContent += `- **Crawled At**: ${new Date().toISOString()}\n\n`;
        mdContent += `## Content\n\n`;
        mdContent += (pageMarkdown || '*No text content extracted.*') + '\n\n';
        mdContent += `## Outbound Links\n\n`;
        if (outboundLinks.length > 0) {
          for (const link of outboundLinks) {
            const cleanLinkTitle = sanitizeFilename(link.title, link.url);
            mdContent += `- [[${cleanLinkTitle}]] ([${link.title || cleanLinkTitle}](${link.url}))\n`;
          }
        } else {
          mdContent += 'No outbound links found on this page.\n';
        }

        // Save to vault
        const filePath = join(vaultDir, `${cleanTitle}.md`);
        await writeFile(filePath, mdContent, 'utf-8');
        console.error(`  📄 Saved: ${cleanTitle}.md → ${vaultDir}`);

        // Add line numbers to content for citation
        const contentLines = mdContent.split('\n');
        const pad = String(contentLines.length).length;
        const numberedContent = contentLines.map((line, i) =>
          `${String(i + 1).padStart(pad, ' ')}|${line}`
        ).join('\n');

        results.push({
          url,
          title: cleanTitle,
          content: mdContent,
          totalLines: contentLines.length,
          outboundLinks: outboundLinks.map(l => ({
            title: sanitizeFilename(l.title, l.url),
            url: l.url,
          })),
        });

      } catch (err) {
        console.error(`  ⚠️  Crawl failed for ${url}: ${err.message}`);
        results.push({
          url,
          title: sanitizeFilename(null, url),
          content: `Crawl failed: ${err.message}`,
          totalLines: 1,
          outboundLinks: [],
          crawlError: err.message,
        });
      } finally {
        await page.close().catch(() => {});
      }
    }
  } catch (err) {
    console.error(`⚠️  Playwright browser error: ${err.message}`);
  } finally {
    if (browser) await browser.close().catch(() => {});
  }

  return results;
}

// ── Debounced reindex: triggers full pipeline (index rebuild + corpus sync) ──
let _reindexTimer = null;
const REINDEX_DELAY_MS = 90_000; // 90s after last crawl trigger
function debouncedAutoReindex() {
  if (_reindexTimer) clearTimeout(_reindexTimer);
  _reindexTimer = setTimeout(() => {
    _reindexTimer = null;
    const NETWORKER_URL = process.env.NETWORKER_API_URL || 'http://127.0.0.1:4090';
    // Call networker /api/mcp/rebuild-index which does the full pipeline:
    //   1. indexer.js (rebuild index.json)
    //   2. AutoRAG /reindex (rebuild corpus + reload search)
    fetch(`${NETWORKER_URL}/api/mcp/rebuild-index`, { method: 'POST' })
      .then(r => r.json())
      .then(d => console.error(`\u{1F504} Full reindex complete: ${d.success ? 'ok' : 'failed'}`))
      .catch(e => console.error(`\u{26A0}\u{FE0F}  Full reindex failed: ${e.message}`));
  }, REINDEX_DELAY_MS);
  console.error(`\u{1F4C5} Full reindex scheduled in ${REINDEX_DELAY_MS / 1000}s (debounced)`);
}

// Load index
const INDEX_FILE = new URL('./index.json', import.meta.url).pathname;
let index = null;
let embedder = null;
let titleToNodeId = new Map();

/**
 * Load the index file
 */
async function loadIndex() {
  try {
    const data = await readFile(INDEX_FILE, 'utf-8');
    index = JSON.parse(data);
    console.error(`📦 Loaded index: ${Object.keys(index.nodes).length} nodes, ${index.edges.length} edges`);
    
    // Build title → nodeId mapping for outbound link resolution
    titleToNodeId = new Map();
    for (const [nid, node] of Object.entries(index.nodes)) {
      titleToNodeId.set(node.title, nid);
    }
  } catch (err) {
    console.error('❌ Failed to load index.json');
    console.error('   Run `node indexer.js` first to build the index.');
    process.exit(1);
  }
}

function findNodeInIndex(targetNodes, targetIdOrUrl) {
  if (!targetNodes || !targetIdOrUrl) return null;
  if (targetNodes[targetIdOrUrl]) return targetNodes[targetIdOrUrl];
  
  try {
    const hash = createHash('md5').update(targetIdOrUrl).digest('hex').substring(0, 16);
    if (targetNodes[`url_${hash}`]) return targetNodes[`url_${hash}`];
  } catch (e) {}

  const normTarget = normalizeUrl(targetIdOrUrl);
  for (const node of Object.values(targetNodes)) {
    if (node.url && normalizeUrl(node.url) === normTarget) return node;
    if (node.sourceUrl && normalizeUrl(node.sourceUrl) === normTarget) return node;
  }
  return null;
}

function normalizeUrl(url) {
  if (!url) return '';
  try {
    const u = new URL(url);
    return (u.hostname + u.pathname).replace(/\/$/, '').toLowerCase();
  } catch {
    return url.replace(/\/$/, '').toLowerCase();
  }
}

function triggerSummaryTask(nodeId, title, userId) {
  console.error(`[Background] Triggered async summary task for node: ${nodeId} (${title})`);
  if (NETWORKER_API_URL) {
    fetch(`${NETWORKER_API_URL}/api/tasks/register`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        id: `summary_${nodeId}_${Date.now()}`,
        seedUrl: `AI Summary: ${title}`,
        status: 'running',
        userId: userId || null
      })
    }).catch(() => {});
  }
}

function getNeighborsData(nodeId, sourceNodes, sourceEdges, userId = null) {
  const neighbors = [];
  const edges = (sourceEdges || []).filter(e => e.source === nodeId || e.from === nodeId);
  for (const e of edges) {
    const targetNodeId = e.target || e.to;
    const targetNode = sourceNodes ? sourceNodes[targetNodeId] : null;
    if (!targetNode) {
      neighbors.push({ nodeId: targetNodeId, title: targetNodeId });
      continue;
    }
    
    let summaryText = targetNode.summary;
    if (!summaryText || summaryText.includes('等待 AI') || summaryText.startsWith('No content')) {
      triggerSummaryTask(targetNodeId, targetNode.title, userId);
      summaryText = summaryText || "等待 AI / 任务抓取中...";
    }
    
    neighbors.push({
      nodeId: targetNodeId,
      title: targetNode.title,
      sourceUrl: targetNode.url || targetNode.sourceUrl || null,
      summary: summaryText
    });
  }
  return neighbors;
}

/**
 * Load the embedding model
 */
async function loadEmbedder() {
  const { pipeline } = await import('@xenova/transformers');
  embedder = await pipeline('feature-extraction', index.model);
  console.error(`🧠 Loaded embedding model: ${index.model}`);
}

/**
 * Compute cosine similarity between two vectors
 */
function cosineSimilarity(a, b) {
  let dot = 0, normA = 0, normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  return dot / (Math.sqrt(normA) * Math.sqrt(normB));
}

/**
 * Semantic search: find top K most similar nodes to query (fallback)
 */
async function semanticSearch(query, topK = 5) {
  if (!embedder) await loadEmbedder();
  
  // Embed the query
  const output = await embedder(query, { pooling: 'mean', normalize: true });
  const queryEmbedding = Array.from(output.data);
  
  // Compute similarity to all nodes
  const results = [];
  for (const [nodeId, embedding] of Object.entries(index.embeddings)) {
    const similarity = cosineSimilarity(queryEmbedding, embedding);
    results.push({ nodeId, similarity });
  }
  
  // Sort by similarity descending
  results.sort((a, b) => b.similarity - a.similarity);
  
  // Return top K
  return results.slice(0, topK);
}

/**
 * AutoRAG search: delegates to the Python AutoRAG API which auto-selects
 * the best retrieval method (BM25, TF-IDF, or Transformer).
 * Falls back to local semanticSearch if API is unreachable.
 */
async function autoragSearch(query, topK = 5, userId = null, filter = []) {
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15000);
    
    const resp = await fetch(`${AUTORAG_API_URL}/search`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ query, limit: topK, userId, filter }),
      signal: controller.signal,
    });
    clearTimeout(timeout);
    
    if (!resp.ok) {
      throw new Error(`AutoRAG API returned ${resp.status}`);
    }
    
    const data = await resp.json();
    return {
      method: data.method || 'unknown',
      results: (data.results || []).map(r => ({
        nodeId: r.nodeId || null,
        title: r.title,
        path: r.path,
        score: r.score,
        content: r.content,
        sourceUrl: r.sourceUrl || null,
        source_type: r.source_type || 'public',
      })),
    };
  } catch (err) {
    console.error(`⚠️  AutoRAG API unavailable (${err.message}), falling back to local search`);
    return null; // signal fallback
  }
}

/**
 * Get all connected node IDs (both inbound and outbound)
 */
function getConnectedNodes(nodeId) {
  const connected = new Set();
  
  for (const edge of index.edges) {
    if (edge.from === nodeId) {
      connected.add(edge.to);
    }
    if (edge.to === nodeId) {
      connected.add(edge.from);
    }
  }
  
  return Array.from(connected);
}

/**
 * Brave Search API: search the live web and return top results.
 */
async function braveSearch(query, count = 5) {
  const url = `${BRAVE_SEARCH_URL}?q=${encodeURIComponent(query)}&count=${count}`;
  const resp = await fetch(url, {
    headers: {
      'Accept': 'application/json',
      'Accept-Encoding': 'gzip',
      'X-Subscription-Token': BRAVE_API_KEY,
    },
  });
  if (!resp.ok) {
    throw new Error(`Brave Search API returned ${resp.status}: ${await resp.text()}`);
  }
  const data = await resp.json();
  return (data.web?.results || []).map(r => ({
    title: r.title || '',
    url: r.url || '',
    description: r.description || '',
    snippet: (r.extra_snippets || []).join(' ').slice(0, 500) || r.description || '',
  }));
}

// Create MCP server
const server = new Server(
  {
    name: 'networker-mcp',
    version: '1.0.0',
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// List tools handler
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'get_recent_emails',
      description: 'Get a chronological list of recent emails from the Gmail private vault. Returns metadata and snippet for each email. You can then use read() to view the full content of any specific email using its returned nodeId (or sourceId if mapped).',
      inputSchema: {
        type: 'object',
        properties: {
          days: {
            type: 'number',
            description: 'Number of days to look back (default 7).'
          }
        }
      }
    },
    {
      name: 'search',
      description: 'Search the knowledge graph across multiple vaults (public campus knowledge, user private course pages, user private Gmail emails, and user personal documents). Supports filtering by source.',
      inputSchema: {
        type: 'object',
        properties: {
          query: {
            type: 'string',
            description: 'The question or search query to find relevant notes',
          },
          limit: {
            type: 'number',
            description: 'Maximum number of results to return (default: 5)',
          },
          userId: {
            type: 'string',
            description: 'The user ID for accessing private vaults',
          },
          filter: {
            type: 'array',
            items: { type: 'string' },
            description: 'Source filters: [] for all sources, ["public"] for public campus knowledge, ["Gmail"] for emails, ["course"] for course pages, ["personal"] for user uploaded documents',
          },
        },
        required: ['query'],
      },
    },
    {
      name: 'read',
      description: 'Read the full content of a specific note by its node ID or Canvas IDs (courseId/moduleId/pageId). Also returns outbound links with their node IDs.',
      inputSchema: {
        type: 'object',
        properties: {
          nodeId: { type: 'string', description: 'The node ID (content hash) of the note to read' },
          userId: { type: 'string', description: 'User ID for private knowledge graph access' },
          courseId: { type: 'string', description: 'Course ID' },
          moduleId: { type: 'string', description: 'Module ID' },
          pageId: { type: 'string', description: 'Page ID / URL slug' },
        },
        required: [],
      },
    },

    {
      name: 'web_search',
      description: 'Search the live web using Brave Search. Returns titles, URLs, and snippets. Does NOT crawl pages — after reviewing results, call expand(url) on URLs you want to read in full. Use this when the knowledge graph does not have relevant information.',
      inputSchema: {
        type: 'object',
        properties: {
          query: {
            type: 'string',
            description: 'The search query for web search',
          },
          limit: {
            type: 'number',
            description: 'Maximum number of results to return (default: 5)',
          },
        },
        required: ['query'],
      },
    },
    {
      name: 'expand',
      description: 'Crawl a URL (1-hop) and save its content to the knowledge vault, returning full line-numbered content with outbound links. Also supports expanding an existing graph node by nodeId to read all its 1-hop neighbors. Use after web_search to get full page content of specific URLs, or on existing nodes to explore connected pages.',
      inputSchema: {
        type: 'object',
        properties: {
          nodeId: {
            type: 'string',
            description: 'The node ID of an existing graph node to expand (reads all 1-hop neighbors)',
          },
          url: {
            type: 'string',
            description: 'A URL to crawl and save to the vault (1-hop). Returns the full page content. Use this after web_search to read specific pages.',
          },
        },
      },
    },
  ],
}));

// Call tool handler
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  
  try {
    switch (name) {
      case 'get_recent_emails': {
        const days = args.days || 7;
        const now = Date.now();
        const cutoff = now - (days * 24 * 60 * 60 * 1000);
        
        let vaultIndexData = index;
        if (args.userId) {
          const uPath = join(__dirname_mcp, 'private_vaults', String(args.userId), 'index.json');
          if (existsSync(uPath)) {
             try { vaultIndexData = JSON.parse(await readFile(uPath, 'utf8')); } catch(e){}
          }
        }
        
        const emails = [];
        for (const [id, node] of Object.entries(vaultIndexData.nodes)) {
          if (id.startsWith('gmail_') && node.date) {
            const d = new Date(node.date).getTime();
            if (d >= cutoff) {
              emails.push({
                nodeId: id,
                title: node.title,
                from: node.from,
                date: node.date,
                path: node.path
              });
            }
          }
        }
        emails.sort((a,b) => new Date(b.date).getTime() - new Date(a.date).getTime());
        
        return {
          content: [{
            type: 'text',
            text: JSON.stringify({
              query: `Recent emails past ${days} days`,
              results: emails,
              total: emails.length
            }, null, 2)
          }]
        };
      }
      case 'search': {
        const query = args.query;
        const limit = args.limit || 5;
        const userId = args.userId || null;
        const filter = args.filter || [];
        
        // Try AutoRAG API first (auto-selects best retrieval method)
        const autoragResult = await autoragSearch(query, limit, userId, filter);
        
        if (autoragResult) {
          // AutoRAG succeeded — enrich results with full node content from index
          const enriched = autoragResult.results.map(r => {
            const node = r.nodeId ? index.nodes[r.nodeId] : null;
            if (node && (!node.summary || node.summary.startsWith('No content'))) triggerSummaryTask(node.id, node.title, userId);
            const nid = r.nodeId || null;
            return {
              nodeId: nid,
              title: r.title,
              path: r.path,
              score: r.score,
              content: node ? node.content : r.content,
              sourceUrl: r.sourceUrl || null,
              neighbors: nid ? getNeighborsData(nid, index.nodes, index.edges, userId) : [],
            };
          });
          
          return {
            content: [
              {
                type: 'text',
                text: JSON.stringify({
                  query,
                  method: autoragResult.method,
                  results: enriched,
                  total: enriched.length,
                }, null, 2),
              },
            ],
          };
        }
        
        // Fallback: local semantic search via @xenova/transformers
        const results = await semanticSearch(query, limit);
        const formattedResults = results.map(({ nodeId, similarity }) => {
          const node = index.nodes[nodeId];
          if (!node) return null;
          if (!node.summary || node.summary.startsWith('No content')) triggerSummaryTask(node.id, node.title, null);
          return {
            nodeId: node.id,
            title: node.title,
            path: node.path,
            similarity: Math.round(similarity * 100) / 100,
            content: node.content,
            neighbors: getNeighborsData(node.id, index.nodes, index.edges, null),
          };
        }).filter(Boolean);
        
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify({
                query,
                method: 'local_embedding_fallback',
                results: formattedResults,
                total: formattedResults.length,
              }, null, 2),
            },
          ],
        };
      }
      
      case 'read': {
        let nodeId = args.nodeId;
        const { userId, courseId, moduleId, pageId } = args;

        let mergedNodes = { ...index.nodes };
        let mergedEdges = [...index.edges];

        if (userId) {
          const privateVaultDir = join(__dirname_mcp, 'private_vaults', userId);
          const privateIndexPath = join(privateVaultDir, 'index.json');
          if (existsSync(privateIndexPath)) {
            try {
              const priv = JSON.parse(await readFile(privateIndexPath, 'utf-8'));
              Object.assign(mergedNodes, priv.nodes);
              if (priv.edges) mergedEdges.push(...priv.edges);
            } catch(e) {}
          }
          if (!nodeId && courseId && pageId) {
             nodeId = `${courseId}_${moduleId || 'none'}_${pageId}`;
          }
        }

        const node = mergedNodes[nodeId];
        
        if (!node) {
          return {
            content: [{ type: 'text', text: JSON.stringify({ error: `Node not found: ${nodeId}` }) }],
            isError: true,
          };
        }
        
        if (!node.summary || node.summary.startsWith('No content')) triggerSummaryTask(node.id, node.title, userId);
        
        const contentLines = (node.content || '').split('\n');
        const pad = String(contentLines.length).length;
        const numberedContent = contentLines.map((line, i) => `${String(i + 1).padStart(pad, ' ')}|${line}`).join('\n');
        
        const neighbors = getNeighborsData(nodeId, mergedNodes, mergedEdges, userId);

        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify({
                nodeId: node.id,
                title: node.title,
                path: node.path,
                content: numberedContent,
                totalLines: contentLines.length,
                neighbors,
              }, null, 2),
            },
          ],
        };
      }

      case 'web_search': {
        const query = args.query;
        const limit = args.limit || 5;
        
        try {
          // Pure Brave Search — no crawling. Agent calls expand(url) to crawl.
          const braveResults = await braveSearch(query, limit);
          
          // Enrich: check which URLs already exist in the graph
          const enrichedResults = braveResults.map(r => {
            let existingNodeId = null;
            for (const [nid, node] of Object.entries(index.nodes)) {
              if (node.sourceUrl === r.url || node.path === r.url) {
                existingNodeId = nid;
                break;
              }
            }
            return {
              title: r.title,
              url: r.url,
              description: r.description,
              snippet: r.snippet,
              nodeId: existingNodeId,
              inGraph: !!existingNodeId,
            };
          });
          
          return {
            content: [
              {
                type: 'text',
                text: JSON.stringify({
                  query,
                  method: 'brave_search',
                  results: enrichedResults,
                  total: enrichedResults.length,
                  hint: 'Call expand(url) on any result URL to crawl it and get full content.',
                }, null, 2),
              },
            ],
          };
        } catch (err) {
          return {
            content: [
              {
                type: 'text',
                text: JSON.stringify({ error: `Web search failed: ${err.message}` }),
              },
            ],
            isError: true,
          };
        }
      }
      
      case 'expand': {
        const nodeId = args.nodeId;
        const url = args.url;
        const userId = args.userId;

        let privateVaultDir = MCP_ASSETS_DIR;
        let privateIndexPath = INDEX_FILE;
        let vaultIndexData = index;

        if (userId) {
          privateVaultDir = join(__dirname_mcp, 'private_vaults', userId);
          privateIndexPath = join(privateVaultDir, 'index.json');
          if (existsSync(privateIndexPath)) {
            try {
              vaultIndexData = JSON.parse(await readFile(privateIndexPath, 'utf-8'));
            } catch (e) {}
          }
        }

        const targetIdentifier = url || nodeId;
        if (!targetIdentifier) {
          return {
            content: [{ type: 'text', text: JSON.stringify({ error: 'Either nodeId or url must be provided.' }) }],
            isError: true,
          };
        }

        let existingNode = findNodeInIndex(vaultIndexData.nodes, targetIdentifier);
        const crawlUrl = url || (existingNode ? (existingNode.url || existingNode.sourceUrl) : null);

        let crawledContent = "";
        let crawledTitle = existingNode ? existingNode.title : null;
        let crawledOutboundLinks = [];

        if (crawlUrl) {
          try {
            console.error(`🕷️  expand: crawling ${crawlUrl} (1-hop)...`);
            const crawlResults = await crawlPagesSync([crawlUrl], privateVaultDir);
            if (crawlResults && crawlResults.length > 0) {
              const crawled = crawlResults[0];
              crawledContent = crawled.content || "";
              crawledTitle = crawled.title || crawledTitle || "Expanded Node";
              crawledOutboundLinks = crawled.outboundLinks || [];
            }
          } catch (err) {
            console.error(`Crawl failed in expand: ${err.message}`);
          }
        } else if (existingNode) {
          crawledContent = existingNode.content || "";
          crawledTitle = existingNode.title;
        }

        if (!crawledContent && !existingNode) {
          return {
            content: [{ type: 'text', text: JSON.stringify({ error: `Node/URL not found or crawl failed for: ${targetIdentifier}` }) }],
            isError: true,
          };
        }

        if (!vaultIndexData.nodes) vaultIndexData.nodes = {};
        if (!vaultIndexData.edges) vaultIndexData.edges = [];

        // Determine target Node ID
        const targetNodeId = existingNode ? existingNode.id : (nodeId || `url_${createHash('md5').update(crawlUrl).digest('hex').substring(0, 16)}`);

        // Update / Replace Content in Vault
        if (!vaultIndexData.nodes[targetNodeId]) {
          vaultIndexData.nodes[targetNodeId] = {
            id: targetNodeId,
            title: crawledTitle || 'Expanded Page',
            url: crawlUrl,
            content: crawledContent
          };
        } else {
          vaultIndexData.nodes[targetNodeId].content = crawledContent;
          if (crawledTitle) vaultIndexData.nodes[targetNodeId].title = crawledTitle;
          if (crawlUrl) vaultIndexData.nodes[targetNodeId].url = crawlUrl;
        }

        // Process and persist 1-hop outbound links and edges
        if (crawledOutboundLinks && crawledOutboundLinks.length > 0) {
          for (const link of crawledOutboundLinks) {
            if (!link.url) continue;
            const linkUrl = link.url;
            const linkTitle = link.title || sanitizeFilename(null, linkUrl);
            const linkHash = createHash('md5').update(linkUrl).digest('hex').substring(0, 16);
            const childNodeId = `url_${linkHash}`;

            if (!vaultIndexData.nodes[childNodeId]) {
              vaultIndexData.nodes[childNodeId] = {
                id: childNodeId,
                title: linkTitle,
                url: linkUrl,
                content: '',
                summary: '等待 AI / 任务抓取中...'
              };
            }

            const edgeExists = vaultIndexData.edges.some(
              e => (e.source === targetNodeId || e.from === targetNodeId) && (e.target === childNodeId || e.to === childNodeId)
            );
            if (!edgeExists) {
              vaultIndexData.edges.push({
                source: targetNodeId,
                target: childNodeId,
                from: targetNodeId,
                to: childNodeId
              });
            }
          }
        }

        const node = vaultIndexData.nodes[targetNodeId];

        // CRITICAL: PRESERVE EXISTING SUMMARY IF PRESENT!
        let mainSummary = node.summary;
        if (!mainSummary || mainSummary.includes('等待 AI')) {
          triggerSummaryTask(targetNodeId, node.title, userId);
          mainSummary = "等待 AI / 任务抓取中...";
          node.summary = mainSummary;
        }

        if (existsSync(privateVaultDir)) {
          await writeFile(privateIndexPath, JSON.stringify(vaultIndexData, null, 2));
          try {
            await fetch('http://127.0.0.1:8002/reindex?fast=true');
          } catch (e) {}
        }

        const contentLines = (node.content || '').split('\n');
        const pad = String(contentLines.length).length;
        const numberedContent = contentLines.map((line, i) => `${String(i + 1).padStart(pad, ' ')}|${line}`).join('\n');

        const neighbors = getNeighborsData(targetNodeId, vaultIndexData.nodes, vaultIndexData.edges, userId);

        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify({
                nodeId: targetNodeId,
                title: node.title,
                sourceUrl: node.url || node.sourceUrl || crawlUrl || null,
                summary: mainSummary,
                content: numberedContent,
                totalLines: contentLines.length,
                neighbors,
                totalNeighbors: neighbors.length,
                message: `Expanded node content replaced/updated in vault. Summary preserved.`,
              }, null, 2),
            },
          ],
        };
      }

      default:
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify({ error: `Unknown tool: ${name}` }),
            },
          ],
          isError: true,
        };
    }
  } catch (err) {
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify({ error: err.message }),
        },
      ],
      isError: true,
    };
  }
});

// Start server
async function main() {
  await loadIndex();
  
  const transport = new StdioServerTransport();
  await server.connect(transport);
  
  console.error('🚀 Networker MCP server started');
  console.error(`   Tools: search (AutoRAG @ ${AUTORAG_API_URL}), read`);
}

main().catch(err => {
  console.error('❌ Server failed:', err);
  process.exit(1);
});
export { crawlPagesSync };
