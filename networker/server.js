require("node:dns").setDefaultResultOrder("ipv4first");
const express = require('express');
const cors = require('cors');
const path = require('path');
const fs = require('fs');
const { exec } = require('child_process');
const { chromium } = require('playwright');
const http = require('http');

const app = express();
const PORT = 4090;

// AutoRAG API URL (networker_mcp.service)
const AUTORAG_API_URL = process.env.AUTORAG_API_URL || 'http://127.0.0.1:8002';

app.use(cors());
app.use(express.json());

// Store crawling tasks in memory
const tasks = new Map();
const VAULT_DIR = path.join(__dirname, 'vault');

// Crawl lock & task queue — only one crawl runs at a time
let crawlLock = false;
const crawlQueue = [];

// ── Indexer debounce: prevents concurrent/rapid indexer.js invocations ──
let _indexerRunning = false;
let _indexerDebounceTimer = null;
const INDEXER_COOLDOWN_MS = 60_000; // 60s cooldown between indexer runs

function enqueueCrawl(taskId) {
  if (!crawlLock) {
    crawlLock = true;
    runCrawler(taskId);
  } else {
    crawlQueue.push(taskId);
    const task = tasks.get(taskId);
    if (task) {
      task.status = 'queued';
      logToTask(taskId, 'Crawl queued — another crawl is in progress.');
      sendTaskEvent(taskId, { type: 'status', data: { status: 'queued' } });
    }
  }
}

function releaseCrawlLock() {
  crawlLock = false;
  if (crawlQueue.length > 0) {
    const nextId = crawlQueue.shift();
    crawlLock = true;
    runCrawler(nextId);
  }
}

// Ensure base vault directory exists
if (!fs.existsSync(VAULT_DIR)) {
  fs.mkdirSync(VAULT_DIR, { recursive: true });
}

// Persistent URL Ban List (Pruning)
const BANLIST_PATH = path.join(__dirname, 'banlist.json');
let banlist = [];
if (fs.existsSync(BANLIST_PATH)) {
  try {
    banlist = JSON.parse(fs.readFileSync(BANLIST_PATH, 'utf-8'));
  } catch (e) {
    console.error('Failed to parse banlist.json, using empty list');
  }
} else {
  // Default common ban list patterns
  banlist = ['wp-login', 'wp-admin', 'wp-content/uploads', '/feed/', '?share='];
  try {
    fs.writeFileSync(BANLIST_PATH, JSON.stringify(banlist, null, 2), 'utf-8');
  } catch (e) {
    console.error('Failed to create banlist.json');
  }
}

// Helper to sanitize titles for Obsidian filenames
function sanitizeObsidianFilename(title, url) {
  if (!title || !title.trim()) {
    try {
      const parsedUrl = new URL(url);
      let filename = parsedUrl.pathname.replace(/^\/|\/$/g, '').replace(/\//g, ' - ') || 'home';
      title = filename;
    } catch (e) {
      title = 'untitled';
    }
  }
  return title
    .replace(/[\\/:*?"<>|#^[\]]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .substring(0, 150);
}

function cleanAnchorText(text) {
  if (!text) return '';
  return text
    .replace(/\s+/g, ' ')
    .replace(/[\\/:*?"<>|#^[\]]/g, '')
    .trim();
}

function getTitleForUrl(url, urlToTitleMap) {
  if (!url || !urlToTitleMap) return null;
  if (urlToTitleMap.has(url)) return urlToTitleMap.get(url);
  
  // Try adding a trailing slash
  const withSlash = url.endsWith('/') ? url : url + '/';
  if (urlToTitleMap.has(withSlash)) return urlToTitleMap.get(withSlash);
  
  // Try removing a trailing slash
  const withoutSlash = url.endsWith('/') ? url.slice(0, -1) : url;
  if (urlToTitleMap.has(withoutSlash)) return urlToTitleMap.get(withoutSlash);
  
  return null;
}

function normalizeUrl(urlStr) {
  try {
    const u = new URL(urlStr);
    u.hash = '';
    return u.toString();
  } catch (e) {
    return urlStr;
  }
}

// Reconstruct a single task from its vault directory
function reconstructTaskFromDir(dirName, fullPath, scanDir) {
  const match = dirName.match(/^(.+)_task_(\d+)$/);
  if (!match) return null;

  const host = match[1];
  const taskId = 'task_' + match[2];
  const isBatch = (host === 'batch');

  // For regular tasks: reconstruct seedUrl from hostname
  // For batch tasks: we'll read the first .md file's Source URL below
  const seedUrl = isBatch ? null : `https://${host.replace(/_/g, '.')}`;

  const task = {
    id: taskId,
    seedUrl: seedUrl || '(batch crawl)',
    seedUrls: isBatch ? [] : undefined,
    maxDepth: 3,
    maxPages: isBatch ? 30 : 50,
    vaultPath: fullPath,
    status: 'completed',
    startTime: parseInt(match[2]),
    endTime: parseInt(match[2]),
    nodes: new Map(),
    edges: [],
    logs: [{ text: `[System] Reconstructed task from disk (${scanDir}).`, isError: false }],
    vaultWrites: [],
    listeners: [],
    aborted: false,
    visited: new Set(),
    knownUrls: new Set(),
    urlToTitle: new Map(),
    urlToImageUrl: new Map()
  };

  const files = fs.readdirSync(fullPath).filter(f => f.endsWith('.md'));
  const nodeUrls = new Map();

  for (const file of files) {
    const title = file.substring(0, file.length - 3);
    let fileContent = '';
    try {
      fileContent = fs.readFileSync(path.join(fullPath, file), 'utf-8');
    } catch (e) {
      continue;
    }
    
    const urlMatch = fileContent.match(/- \*\*Source URL\*\*: \[(.*?)\]/);
    const url = urlMatch ? urlMatch[1] : `https://${host}/${title}`;

    nodeUrls.set(title, url);
    task.visited.add(url);
    task.knownUrls.add(url);
    task.urlToTitle.set(url, title);
    
    task.nodes.set(url, {
      id: url,
      label: title,
      url: url,
      depth: 0,
      status: 'visited'
    });
  }

  // For batch tasks: reconstruct seedUrl from the first .md file's Source URL
  if (isBatch && nodeUrls.size > 0) {
    const firstUrl = nodeUrls.values().next().value;
    task.seedUrl = firstUrl;
    task.seedUrls = [firstUrl];
  }

  for (const file of files) {
    const title = file.substring(0, file.length - 3);
    const url = nodeUrls.get(title);
    if (!url) continue;

    let fileContent = '';
    try {
      fileContent = fs.readFileSync(path.join(fullPath, file), 'utf-8');
    } catch (e) {
      continue;
    }

    // Reconstruct image URLs from markdown image embeds
    const imgRegex = /!\[(.*?)\]\((.*?)\)/g;
    let imgMatch;
    while ((imgMatch = imgRegex.exec(fileContent)) !== null) {
      const imgTitle = imgMatch[1];
      const imgUrl = imgMatch[2];
      task.urlToImageUrl.set(imgUrl, imgUrl);
      task.urlToTitle.set(imgUrl, imgTitle);
    }

    const wikilinkRegex = /\[\[(.*?)\]\]/g;
    let linkMatch;
    while ((linkMatch = wikilinkRegex.exec(fileContent)) !== null) {
      let targetTitle = linkMatch[1];
      // Split out any anchor text (e.g. [[Title|Anchor]])
      if (targetTitle.includes('|')) {
        targetTitle = targetTitle.split('|')[0];
      }
      const targetUrl = nodeUrls.get(targetTitle) || `https://${host}/${targetTitle}`;

      task.knownUrls.add(targetUrl);
      if (!task.urlToTitle.has(targetUrl)) {
        task.urlToTitle.set(targetUrl, targetTitle);
      }
      task.edges.push({ from: url, to: targetUrl });

      if (!task.nodes.has(targetUrl)) {
        task.nodes.set(targetUrl, {
          id: targetUrl,
          label: targetTitle,
          url: targetUrl,
          depth: 1,
          status: 'pending'
        });
      }
    }
  }

  return { taskId, task };
}

// Reconstruct historical tasks from disk (scans both vault/ and MCP/assets/)
function loadCompletedTasksFromDisk() {
  try {
    const dirsToScan = [
      { dir: VAULT_DIR, label: 'vault' },
    ];

    // Also scan MCP/assets/ for batch crawl tasks triggered by web_search
    const mcpAssetsDir = path.join(__dirname, 'MCP', 'assets');
    if (fs.existsSync(mcpAssetsDir)) {
      dirsToScan.push({ dir: mcpAssetsDir, label: 'MCP/assets' });
    }

    for (const { dir: scanDir, label } of dirsToScan) {
      if (!fs.existsSync(scanDir)) continue;
      const dirs = fs.readdirSync(scanDir);

      for (const dirName of dirs) {
        const fullPath = path.join(scanDir, dirName);
        if (!fs.statSync(fullPath).isDirectory()) continue;

        const result = reconstructTaskFromDir(dirName, fullPath, label);
        if (result) {
          tasks.set(result.taskId, result.task);
        }
      }
    }
    console.log(`Reconstructed ${tasks.size} historical tasks from disk.`);
  } catch (e) {
    console.error('Failed to load completed tasks from disk:', e);
  }
}

// SSE helper to broadcast to listeners of a task
function sendTaskEvent(taskId, event) {
  const task = tasks.get(taskId);
  if (task && task.listeners) {
    task.listeners.forEach(res => {
      res.write(`data: ${JSON.stringify(event)}\n\n`);
    });
  }
}

function logToTask(taskId, message, isError = false) {
  const task = tasks.get(taskId);
  if (task) {
    const timestampedMsg = `[${new Date().toLocaleTimeString()}] ${message}`;
    task.logs.push({ text: timestampedMsg, isError });
    sendTaskEvent(taskId, { type: 'log', data: { text: timestampedMsg, isError } });
  }
}

// Crawler logic
async function runCrawler(taskId) {
  const task = tasks.get(taskId);
  if (!task) return;

  task.status = 'crawling';
  sendTaskEvent(taskId, { type: 'status', data: { status: 'crawling' } });

  let browser;
  let knownUrls;
  let queue;
  let visited;
  let urlToTitle;
  let urlToImageUrl;
  let edges;

  try {
    if (!fs.existsSync(task.vaultPath)) {
      fs.mkdirSync(task.vaultPath, { recursive: true });
    }

    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({
      userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    });

    // Support multiple seed URLs (batch mode) or single seed URL
    const seedUrls = task.seedUrls || [task.seedUrl];
    knownUrls = new Set(seedUrls.map(u => normalizeUrl(u)));
    queue = seedUrls.map(u => ({ url: normalizeUrl(u), depth: 0 }));
    visited = new Set();
    urlToTitle = new Map();
    urlToImageUrl = new Map();
    edges = [];

    // Check if we need to inherit from a parent task
    if (task.inheritTaskId) {
      const parentTask = tasks.get(task.inheritTaskId);
      if (parentTask) {
        logToTask(taskId, `Inheriting network state from task: ${task.inheritTaskId}`);
        
        // 1. Copy parent vault files if they exist
        if (fs.existsSync(parentTask.vaultPath)) {
          try {
            fs.cpSync(parentTask.vaultPath, task.vaultPath, { recursive: true });
            logToTask(taskId, `Copied parent files from ${parentTask.vaultPath} to ${task.vaultPath}`);
          } catch (err) {
            logToTask(taskId, `Warning: Failed to copy parent vault files: ${err.message}`);
          }
        }
        
        // 2. Inherit visited set (so we don't crawl them again)
        if (parentTask.visited) {
          parentTask.visited.forEach(u => visited.add(u));
        }
        // 3. Inherit knownUrls set
        if (parentTask.knownUrls) {
          parentTask.knownUrls.forEach(u => knownUrls.add(u));
        }
        // 4. Inherit urlToTitle map
        if (parentTask.urlToTitle) {
          for (const [u, t] of parentTask.urlToTitle) {
            urlToTitle.set(u, t);
          }
        }
        // 5. Inherit urlToImageUrl map
        if (parentTask.urlToImageUrl) {
          for (const [u, img] of parentTask.urlToImageUrl) {
            urlToImageUrl.set(u, img);
          }
        }
        // 6. Inherit edges
        if (parentTask.edges) {
          parentTask.edges.forEach(e => edges.push({ ...e }));
        }
        // 7. Inherit nodes
        if (parentTask.nodes) {
          for (const [u, node] of parentTask.nodes) {
            task.nodes.set(u, { ...node });
            // Send SSE events for inherited nodes so the frontend graph loads them immediately!
            sendTaskEvent(taskId, { type: 'node-added', data: { ...node } });
          }
        }
        // 8. Inherit edges (send SSE events so frontend graph renders them immediately!)
        edges.forEach(e => {
          sendTaskEvent(taskId, { type: 'edge-added', data: e });
        });
        // 9. Inherit vaultWrites
        if (parentTask.vaultWrites) {
          parentTask.vaultWrites.forEach(w => task.vaultWrites.push({ ...w }));
        }
      } else {
        logToTask(taskId, `Warning: Inherit task ID ${task.inheritTaskId} not found. Running fresh crawl.`);
      }
    }

    logToTask(taskId, `Starting crawl from ${seedUrls.length} seed URL(s): ${seedUrls.join(', ')}`);

    while (queue.length > 0) {
      if (task.aborted) {
        logToTask(taskId, `Crawl aborted by user.`);
        break;
      }

      const { url, depth } = queue.shift();
      if (visited.has(url)) continue;

      visited.add(url);
      logToTask(taskId, `Visiting (${visited.size} visited, ${queue.length} in queue, depth ${depth}): ${url}`);

      const page = await context.newPage();
      await page.route('**/*', (route) => {
        const type = route.request().resourceType();
        if (['image', 'media', 'font', 'stylesheet'].includes(type)) {
          route.abort();
        } else {
          route.continue();
        }
      });

      try {
        await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 15000 });
        
        let rawTitle = await page.title();
        if (rawTitle === 'Client Challenge') {
          logToTask(taskId, `Encountered WAF Client Challenge for ${url}, waiting for solution...`);
          for (let attempt = 0; attempt < 8; attempt++) {
            await page.waitForTimeout(1000);
            rawTitle = await page.title();
            if (rawTitle && rawTitle !== 'Client Challenge') {
              logToTask(taskId, `WAF Client Challenge solved successfully! Waiting for page to load...`);
              await page.waitForSelector('main, article, #main, #content, .content', { timeout: 10000 }).catch(() => {});
              await page.waitForTimeout(2000);
              break;
            }
          }
        }
        
        const finalUrl = page.url();
        let isImage = false;
        try {
          const parsedFinal = new URL(finalUrl);
          isImage = /\.(png|jpg|jpeg|gif|svg)(\?.*)?$/i.test(parsedFinal.pathname);
        } catch {}

        if (isImage) {
          logToTask(taskId, `Redirected to image resource: ${finalUrl}. Mapping link directly.`);
          urlToImageUrl.set(url, finalUrl);
          
          let rawTitle = await page.title().catch(() => '');
          const cleanTitle = sanitizeObsidianFilename(rawTitle || finalUrl.split('/').pop().split('?')[0], url);
          urlToTitle.set(url, cleanTitle);
          
          task.nodes.delete(url);
          sendTaskEvent(taskId, { type: 'node-deleted', data: { id: url } });
          
          await page.close().catch(() => {});
          await new Promise(r => setTimeout(r, 400));
          continue;
        }

        const cleanTitle = sanitizeObsidianFilename(rawTitle, url);
        urlToTitle.set(url, cleanTitle);

        const nodeData = { id: url, label: cleanTitle, url, depth, status: 'visited' };
        task.nodes.set(url, nodeData);
        sendTaskEvent(taskId, { type: 'node-added', data: nodeData });

        // Convert HTML content directly to clean Markdown using DOM walker
        const pageMarkdown = await page.evaluate(() => {
          const selectors = ['main', 'article', '#content', '#main', '.content', '.main'];
          let root = null;
          for (const sel of selectors) {
            root = document.querySelector(sel);
            if (root) break;
          }
          if (!root) {
            root = document.body;
          }
          
          function toMarkdown(node) {
            if (!node) return '';
            const ignoreTags = ['SCRIPT', 'STYLE', 'NAV', 'HEADER', 'FOOTER', 'IFRAME', 'NOSCRIPT', 'SVG', 'FORM', 'INPUT', 'BUTTON'];
            if (ignoreTags.includes(node.tagName)) return '';

            if (node.nodeType === Node.TEXT_NODE) {
              return node.nodeValue.replace(/\s+/g, ' ');
            }

            if (node.nodeType !== Node.ELEMENT_NODE) return '';

            let childrenMarkdown = Array.from(node.childNodes)
              .map(child => toMarkdown(child))
              .join('');

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
              case 'STRONG':
              case 'B': return `**${childrenMarkdown.trim()}**`;
              case 'EM':
              case 'I': return `*${childrenMarkdown.trim()}*`;
              case 'LI': return `\n- ${childrenMarkdown.trim()}`;
              case 'UL': return `\n${childrenMarkdown.trim()}\n`;
              case 'OL': return `\n${childrenMarkdown.trim()}\n`;
              case 'A': {
                const href = node.getAttribute('href');
                const text = childrenMarkdown.trim();
                if (!text) return '';
                try {
                  const absoluteUrl = new URL(href, window.location.href);
                  const isImage = /\.(png|jpg|jpeg|gif|svg)$/i.test(absoluteUrl.pathname);
                  if (isImage) {
                    return `![${text}](${absoluteUrl.toString()})`;
                  }
                } catch (e) {}
                return href ? `[${text}](${href})` : text;
              }
              case 'IMG': {
                const src = node.getAttribute('src');
                const alt = node.getAttribute('alt') || '';
                if (!src) return '';
                try {
                  const absoluteUrl = new URL(src, window.location.href);
                  return `![${alt}](${absoluteUrl.toString()})`;
                } catch (e) {
                  return `![${alt}](${src})`;
                }
              }
              case 'DIV':
              case 'SPAN':
              default:
                return childrenMarkdown;
            }
          }
          
          return toMarkdown(root).replace(/\n{3,}/g, '\n\n').trim();
        });

        const linkItems = await page.evaluate(() => {
          return Array.from(document.querySelectorAll('a'))
            .map(a => ({
              href: a.href,
              text: a.innerText || a.getAttribute('title') || ''
            }))
            .filter(item => item.href);
        });

        const internalLinks = [];

        for (let item of linkItems) {
          try {
            const absoluteUrl = new URL(item.href, url);
            if (absoluteUrl.protocol === 'http:' || absoluteUrl.protocol === 'https:') {
              const targetUrl = normalizeUrl(absoluteUrl.toString());

              if (/\.(zip|pdf|png|jpg|jpeg|gif|mp4|mp3|exe|tar|gz|xlsx|docx)$/i.test(absoluteUrl.pathname)) {
                continue;
              }

              // Prune URL if it matches any pattern in the ban list
              const isBanned = banlist.some(pattern => targetUrl.includes(pattern));
              if (isBanned) {
                continue;
              }

              const isKnown = knownUrls.has(targetUrl);

              if (isKnown) {
                // Connection between already known nodes (always recorded)
                if (!internalLinks.includes(targetUrl)) {
                  internalLinks.push(targetUrl);
                }
                edges.push({ from: url, to: targetUrl });
                sendTaskEvent(taskId, { type: 'edge-added', data: { from: url, to: targetUrl } });
              } else {
                // If it is a new node, only add it if we have not hit the maxPages limit (maxPages: 0 means unlimited)
                const limitNotHit = (task.maxPages === 0 || knownUrls.size < task.maxPages);
                if (limitNotHit && depth + 1 <= task.maxDepth) {
                  knownUrls.add(targetUrl);
                  
                  if (!internalLinks.includes(targetUrl)) {
                    internalLinks.push(targetUrl);
                  }
                  edges.push({ from: url, to: targetUrl });
                  sendTaskEvent(taskId, { type: 'edge-added', data: { from: url, to: targetUrl } });

                  const cleanedText = cleanAnchorText(item.text);
                  let label = cleanedText;
                  if (!label || label.length < 2) {
                    try {
                      label = absoluteUrl.pathname.replace(/^\/|\/$/g, '') || 'link';
                    } catch {
                      label = 'link';
                    }
                  }
                  
                  const pendingNode = { id: targetUrl, label: label, url: targetUrl, depth: depth + 1, status: 'pending' };
                  task.nodes.set(targetUrl, pendingNode);
                  sendTaskEvent(taskId, { type: 'node-added', data: pendingNode });

                  queue.push({ url: targetUrl, depth: depth + 1 });
                }
              }
            }
          } catch (e) {}
        }

        task.vaultWrites.push({ url, title: cleanTitle, links: internalLinks, pageMarkdown });
        await page.close();
      } catch (err) {
        logToTask(taskId, `Error visiting ${url}: ${err.message}`, true);
        const nodeData = { id: url, label: getTitleForUrl(url, urlToTitle) || url, url, depth, status: 'error', error: err.message };
        task.nodes.set(url, nodeData);
        sendTaskEvent(taskId, { type: 'node-added', data: nodeData });
        await page.close().catch(() => {});
      }

      await new Promise(r => setTimeout(r, 400));
    }

    logToTask(taskId, `Writing Obsidian markdown files inside ${task.vaultPath}...`);
    for (const writeItem of task.vaultWrites) {
      const { url, title, links, pageMarkdown = '' } = writeItem;
      const filePath = path.join(task.vaultPath, `${title}.md`);
      
      let markdownContent = `# ${title}\n\n`;
      markdownContent += `- **Source URL**: [${url}](${url})\n`;
      markdownContent += `- **Crawled At**: ${new Date().toISOString()}\n\n`;
      
      markdownContent += `## Content\n\n`;
      if (pageMarkdown) {
        const processedMarkdown = convertMarkdownLinksToWikilinks(pageMarkdown, urlToTitle, url, urlToImageUrl);
        markdownContent += `${processedMarkdown}\n\n`;
      } else {
        markdownContent += `*No text content extracted.*\n\n`;
      }

      markdownContent += `## Outbound Links\n\n`;
      for (const link of links) {
        if (urlToImageUrl.has(link)) {
          continue;
        }
        const title = getTitleForUrl(link, urlToTitle) || sanitizeObsidianFilename('', link);
        markdownContent += `- [[${title}]]\n`;
      }
      if (links.length === 0) {
        markdownContent += `No outbound links found on this page.\n`;
      }

      fs.writeFileSync(filePath, markdownContent, 'utf-8');
    }

    if (task.status === 'crawling') {
      task.status = 'completed';
    }
    task.endTime = Date.now();
    logToTask(taskId, `Crawl finished. Saved to ${task.vaultPath}.`);
    sendTaskEvent(taskId, { type: 'status', data: { status: task.status } });

    // Auto-rebuild MCP index if vault was written to MCP assets
    if (task.autoRebuildIndex) {
      logToTask(taskId, 'Auto-rebuilding MCP index (debounced)...');
      debouncedRebuildMcpIndex();
    }

  } catch (globalError) {
    task.status = 'error';
    task.endTime = Date.now();
    logToTask(taskId, `Crawl task failed: ${globalError.message}`, true);
    sendTaskEvent(taskId, { type: 'status', data: { status: 'error', message: globalError.message } });
  } finally {
    if (visited) task.visited = visited;
    if (knownUrls) task.knownUrls = knownUrls;
    if (urlToTitle) task.urlToTitle = urlToTitle;
    if (urlToImageUrl) task.urlToImageUrl = urlToImageUrl;
    if (edges) task.edges = edges;
    if (browser) {
      await browser.close().catch(() => {});
    }
    // Release lock and start next queued task
    releaseCrawlLock();
  }
}

/**
 * Rebuild MCP index programmatically (without HTTP response).
 * Incremental by default — only re-embeds changed files.
 * Debounced: skips if another indexer is running or cooldown is active.
 * Returns true on success, false on failure/skipped.
 */
function rebuildMcpIndex() {
  return new Promise((resolve) => {
    if (_indexerRunning) {
      console.log('[Auto-rebuild] Indexer already running, skipping.');
      resolve(false);
      return;
    }
    _indexerRunning = true;
    const mcpDir = path.join(__dirname, 'MCP');
    const nodePath = '/root/.nvm/versions/node/v24.12.0/bin/node';
    const indexerPath = path.join(mcpDir, 'indexer.js');
    // Incremental mode (no --force): only re-embeds new/changed files
    exec(`${nodePath} ${indexerPath}`, { cwd: mcpDir, timeout: 120000 }, (error) => {
      _indexerRunning = false;
      if (error) {
        console.error('[Auto-rebuild] MCP index rebuild failed:', error.message);
        resolve(false);
      } else {
        console.log("[Auto-rebuild] MCP index rebuilt successfully (incremental).");
        // Chain: trigger AutoRAG /reindex to rebuild corpus from updated index
        const autoragUrl = process.env.AUTORAG_API_URL || "http://127.0.0.1:8002";
        fetch(`${autoragUrl}/reindex`, { method: "POST", timeout: 300000 })
          .then(r => r.json())
          .then(d => console.log(`[Auto-rebuild] AutoRAG reindex: ${d.success ? "ok" : "skipped"}`))
          .catch(e => console.error(`[Auto-rebuild] AutoRAG reindex failed: ${e.message}`));
        resolve(true);
      }
    });
  });
}

/**
 * Debounced rebuild: waits for cooldown before triggering indexer.
 * Multiple calls within the cooldown window are merged into one.
 */
function debouncedRebuildMcpIndex() {
  if (_indexerDebounceTimer) {
    clearTimeout(_indexerDebounceTimer);
  }
  _indexerDebounceTimer = setTimeout(() => {
    _indexerDebounceTimer = null;
    rebuildMcpIndex().catch(() => {});
  }, INDEXER_COOLDOWN_MS);
  console.log(`[Auto-rebuild] Indexer scheduled in ${INDEXER_COOLDOWN_MS / 1000}s (debounced).`);
}

// REST Endpoints
app.post('/api/tasks', (req, res) => {
  const { url, maxDepth = 3, maxPages = 50, vaultPath, inheritTaskId } = req.body;
  if (!url) {
    return res.status(400).json({ error: 'Seed URL is required' });
  }

  const taskId = 'task_' + Date.now();
  const host = new URL(url).host.replace(/[^a-zA-Z0-9.-]/g, '_');
  
  const targetVaultDir = vaultPath ? path.resolve(vaultPath) : VAULT_DIR;
  const taskVaultPath = path.join(targetVaultDir, `${host}_${taskId}`);

  const task = {
    id: taskId,
    seedUrl: url,
    maxDepth: parseInt(maxDepth),
    maxPages: parseInt(maxPages),
    vaultPath: taskVaultPath,
    inheritTaskId: inheritTaskId || null,
    status: 'pending',
    startTime: Date.now(),
    endTime: null,
    nodes: new Map(),
    logs: [],
    vaultWrites: [],
    listeners: [],
    aborted: false
  };

  tasks.set(taskId, task);
  enqueueCrawl(taskId);

  res.json({
    id: taskId,
    seedUrl: url,
    status: task.status,
    vaultPath: taskVaultPath,
    inheritTaskId: task.inheritTaskId
  });
});

// ── Batch crawl: multiple seed URLs, output to specified vault, auto-rebuild index ──
app.post('/api/tasks/batch', (req, res) => {
  const { urls, maxDepth = 3, maxPages = 50, vaultPath } = req.body;
  if (!Array.isArray(urls) || urls.length === 0) {
    return res.status(400).json({ error: 'urls array is required and must not be empty' });
  }

  const taskId = 'task_' + Date.now();
  // Use first URL's host for naming, or "batch" if multiple hosts
  const hosts = [...new Set(urls.map(u => { try { return new URL(u).host; } catch { return 'unknown'; } }))];
  const hostLabel = hosts.length === 1 ? hosts[0].replace(/[^a-zA-Z0-9.-]/g, '_') : 'batch';

  const targetVaultDir = vaultPath ? path.resolve(vaultPath) : VAULT_DIR;
  const taskVaultPath = path.join(targetVaultDir, `${hostLabel}_${taskId}`);

  const task = {
    id: taskId,
    seedUrl: urls[0],
    seedUrls: urls,
    maxDepth: parseInt(maxDepth),
    maxPages: parseInt(maxPages),
    vaultPath: taskVaultPath,
    inheritTaskId: null,
    status: 'pending',
    startTime: Date.now(),
    endTime: null,
    nodes: new Map(),
    logs: [],
    vaultWrites: [],
    listeners: [],
    aborted: false,
    autoRebuildIndex: !!vaultPath,  // auto-rebuild when vault path is explicitly specified
  };

  tasks.set(taskId, task);
  enqueueCrawl(taskId);

  res.json({
    id: taskId,
    seedUrls: urls,
    status: task.status,
    vaultPath: taskVaultPath,
  });
});

app.post('/api/tasks/register', (req, res) => {
  const { id, userId, seedUrl, type, status, vaultPath } = req.body;
  const taskId = id || 'task_' + Date.now();
  const task = {
    id: taskId,
    userId: userId || null,
    seedUrl: seedUrl || '1-Hop Crawl Task',
    type: type || '1hop_crawl',
    status: status || 'running',
    startTime: Date.now(),
    endTime: null,
    vaultPath: vaultPath || '',
    nodes: new Map(),
    logs: [],
    vaultWrites: [],
    listeners: [],
    aborted: false
  };
  tasks.set(taskId, task);
  res.json({ success: true, taskId, task: { id: taskId, userId: task.userId, status: task.status } });

  if (taskId.startsWith('summary_')) {
    setTimeout(async () => {
      try {
        const nodeId = taskId.replace('summary_', '').replace(/_\d+$/, '');
        const uId = task.userId;
        const indexPath = uId 
          ? path.join(__dirname, 'MCP', 'private_vaults', uId, 'index.json')
          : path.join(__dirname, 'MCP', 'index.json');
        
        if (!fs.existsSync(indexPath)) {
          task.status = 'failed';
          task.endTime = Date.now();
          sendTaskEvent(taskId, { type: 'status', data: { status: 'failed' } });
          return;
        }
        
        let indexData = JSON.parse(fs.readFileSync(indexPath, 'utf-8'));
        const node = indexData.nodes[nodeId];
        
        if (!node || node.summary) {
          task.status = 'completed';
          task.endTime = Date.now();
          sendTaskEvent(taskId, { type: 'status', data: { status: 'completed' } });
          return;
        }
        
        let contentToSummarize = node.content || '';
        if (contentToSummarize.length < 50) {
          if (contentToSummarize.trim().length > 0) {
            node.summary = contentToSummarize;
          } else {
            task.status = 'failed';
            task.endTime = Date.now();
            sendTaskEvent(taskId, { type: 'status', data: { status: 'failed' } });
            return;
          }
        } else {
          const DEEPSEEK_API_KEY = process.env.DEEPSEEK_API_KEY || '';
          const resp = await fetch('https://api.deepseek.com/chat/completions', {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'Authorization': `Bearer ${DEEPSEEK_API_KEY}`
            },
            body: JSON.stringify({
              model: 'deepseek-chat',
              messages: [
                { role: 'system', content: 'You are an AI assistant. Provide a concise, clear summary (in Chinese if the context implies, otherwise default language) of the following content. Keep it under 200 words and focus on core information.' },
                { role: 'user', content: contentToSummarize.substring(0, 8000) }
              ]
            })
          });
          const jsonResp = await resp.json();
          if (jsonResp.choices && jsonResp.choices[0] && jsonResp.choices[0].message) {
             node.summary = "[AI Summary Generated] " + jsonResp.choices[0].message.content.trim();
          } else {
             node.summary = contentToSummarize.substring(0, 500) + '... (AI Summary failed)';
          }
        }
        
        fs.writeFileSync(indexPath, JSON.stringify(indexData, null, 2));
        task.status = 'completed';
        task.endTime = Date.now();
        sendTaskEvent(taskId, { type: 'status', data: { status: 'completed' } });
        
      } catch (err) {
        console.error('Summary Task Error:', err.message);
        task.status = 'failed';
        task.endTime = Date.now();
        task.logs.push(err.message);
        
        // Write the error state into the graph so the user knows it failed and it doesn't stay null
        try {
          const nodeId = taskId.replace('summary_', '').replace(/_\d+$/, '');
          const uId = task.userId;
          const indexPath = uId 
            ? path.join(__dirname, 'MCP', 'private_vaults', uId, 'index.json')
            : path.join(__dirname, 'MCP', 'index.json');
          if (fs.existsSync(indexPath)) {
            let indexData = JSON.parse(fs.readFileSync(indexPath, 'utf-8'));
            if (indexData.nodes[nodeId]) {
              indexData.nodes[nodeId].summary = "[AI Summary Failed] 生成总结时发生网络错误或超时: " + err.message;
              fs.writeFileSync(indexPath, JSON.stringify(indexData, null, 2));
            }
          }
        } catch (writeErr) {
          console.error('Failed to write error state to index.json:', writeErr);
        }
        
        sendTaskEvent(taskId, { type: 'status', data: { status: 'failed' } });
      }
    }, 0);
  }
});

app.post('/api/tasks/:id/status', (req, res) => {
  const taskId = req.params.id;
  const { status, error } = req.body;
  const task = tasks.get(taskId);
  if (task) {
    if (status) task.status = status;
    if (status === 'completed' || status === 'failed') task.endTime = Date.now();
    if (error) task.logs.push(`[ERROR] ${error}`);
    return res.json({ success: true, task: { id: taskId, status: task.status } });
  }
  res.status(404).json({ error: 'Task not found' });
});

app.get('/api/tasks', (req, res) => {
  const queryUserId = req.query.userId;
  let list = Array.from(tasks.values());

  if (queryUserId) {
    list = list.filter(task => {
      if (task.userId && task.userId === queryUserId) return true;
      if (task.vaultPath && task.vaultPath.includes(queryUserId)) return true;
      return false;
    });
  }

  const result = list.map(task => ({
    id: task.id,
    userId: task.userId || (task.vaultPath && task.vaultPath.includes('private_vaults') ? task.vaultPath.split('private_vaults/')[1]?.split('/')[0] : null),
    seedUrl: task.seedUrl,
    type: task.type || 'crawl',
    status: task.status,
    startTime: task.startTime,
    endTime: task.endTime,
    vaultPath: task.vaultPath,
    nodesCount: task.nodes ? task.nodes.size : 0,
    inheritTaskId: task.inheritTaskId
  }));
  res.json(result);
});


// ── Vault Downloads (Public / Private / Merged) ─────────────────────────
const { mkdirSync, copyFileSync } = require('fs');

app.get('/api/vault/download/public', (req, res) => {
  createAndSendVaultZip(req, res, 'public', (mdContent) => !mdContent.includes('- **User ID**:'));
});

app.get('/api/vault/download/private/:userId', (req, res) => {
  const targetId = req.params.userId;
  const privateIndexPath = path.join(__dirname, 'MCP', 'private_vaults', targetId, 'index.json');
  if (!fs.existsSync(privateIndexPath)) {
    return res.status(404).json({ error: 'Private vault not found for this user.' });
  }
  
  const privateIndex = JSON.parse(fs.readFileSync(privateIndexPath, 'utf-8'));
  const tmpVault = path.join(__dirname, `tmp_private_vault_${targetId}_${Date.now()}`);
  fs.mkdirSync(tmpVault, { recursive: true });
  
  let count = 0;
  for (const nodeId of Object.keys(privateIndex.nodes)) {
    const node = privateIndex.nodes[nodeId];
    
    // Find all outbound edges for this node to append as Obsidian wikilinks
    const outboundEdges = (privateIndex.edges || []).filter(e => e.source === nodeId);
    let wikilinksBlock = '';
    if (outboundEdges.length > 0) {
      wikilinksBlock = '\n\n---\n**Graph Links:**\n' + outboundEdges.map(e => {
        const targetNode = privateIndex.nodes[e.target];
        if (!targetNode) return '';
        const targetSafeTitle = (targetNode.title || e.target).replace(/[\/\?<>\\:\*\|"]/g, '_');
        return `[[${targetSafeTitle}]]`;
      }).filter(Boolean).join('\n');
    }

    if (node.content) {
      // It's a full page node with markdown content
      const safeTitle = (node.title || nodeId).replace(/[\/\?<>\\:\*\|"]/g, '_');
      fs.writeFileSync(path.join(tmpVault, `${safeTitle}.md`), node.content + wikilinksBlock, 'utf-8');
      count++;
    } else {
      // It's a link node, create a stub with the URL
      const safeTitle = (node.title || nodeId).replace(/[\/\?<>\\:\*\|"]/g, '_');
      const content = `# ${node.title}\n\n**URL**: [${node.url}](${node.url})` + wikilinksBlock;
      fs.writeFileSync(path.join(tmpVault, `${safeTitle}.md`), content, 'utf-8');
      count++;
    }
  }
  
  const uniqueSuffix = Date.now();
  const zipFileName = `private_vault_${targetId}_${uniqueSuffix}.zip`;
  const zipFilePath = path.join(__dirname, zipFileName);
  
  exec(`zip -r "${zipFilePath}" "${path.basename(tmpVault)}"`, { cwd: __dirname }, (error) => {
    fs.rmSync(tmpVault, { recursive: true, force: true });
    if (error) {
      console.error('Zip execution failed:', error);
      return res.status(500).json({ error: 'Failed to create zip package' });
    }
    res.download(zipFilePath, zipFileName, (err) => {
      try {
        if (fs.existsSync(zipFilePath)) fs.unlinkSync(zipFilePath);
      } catch (e) {}
    });
  });
});

app.get('/api/vault/download/merged/:userId', (req, res) => {
  const targetId = req.params.userId;
  createAndSendVaultZip(req, res, `merged_${targetId}`, (mdContent) => !mdContent.includes('- **User ID**:') || mdContent.includes(`- **User ID**: ${targetId}`));
});

function createAndSendVaultZip(req, res, name, filterFn) {
  const assetsDir = path.join(__dirname, 'MCP', 'assets');
  if (!fs.existsSync(assetsDir)) return res.status(404).json({ error: 'Assets directory not found' });
  
  const tmpVault = path.join(__dirname, `tmp_vault_${name}_${Date.now()}`);
  fs.mkdirSync(tmpVault, { recursive: true });
  
  const files = fs.readdirSync(assetsDir);
  let count = 0;
  for (const file of files) {
    if (!file.endsWith('.md')) continue;
    const content = fs.readFileSync(path.join(assetsDir, file), 'utf8');
    if (filterFn(content)) {
      fs.copyFileSync(path.join(assetsDir, file), path.join(tmpVault, file));
      count++;
    }
  }
  
  const zipFileName = `${name}.zip`;
  const zipFilePath = path.join(__dirname, zipFileName);
  
  exec(`zip -r "${zipFilePath}" "${path.basename(tmpVault)}"`, { cwd: __dirname }, (error) => {
    fs.rmSync(tmpVault, { recursive: true, force: true });
    if (error) {
      console.error('Zip execution failed:', error);
      return res.status(500).json({ error: 'Failed to create zip package' });
    }
    res.download(zipFilePath, zipFileName, (err) => {
      try {
        if (fs.existsSync(zipFilePath)) fs.unlinkSync(zipFilePath);
      } catch (e) {}
    });
  });
}

// ZIP Vault download endpoint
app.get('/api/tasks/:id/download', (req, res) => {
  const task = tasks.get(req.params.id);
  if (!task || !fs.existsSync(task.vaultPath)) {
    return res.status(404).json({ error: 'Vault folder not found' });
  }

  const parentDir = path.dirname(task.vaultPath);
  const folderName = path.basename(task.vaultPath);
  const zipFileName = `${folderName}.zip`;
  const zipFilePath = path.join(parentDir, zipFileName);

  exec(`zip -r "${zipFilePath}" "${folderName}"`, { cwd: parentDir }, (error) => {
    if (error) {
      console.error('Zip execution failed:', error);
      return res.status(500).json({ error: 'Failed to create zip package' });
    }

    res.download(zipFilePath, zipFileName, (err) => {
      try {
        if (fs.existsSync(zipFilePath)) {
          fs.unlinkSync(zipFilePath);
        }
      } catch (cleanupErr) {
        console.error('Failed to remove temporary zip file:', cleanupErr);
      }
    });
  });
});

// Download entire MCP assets vault as ZIP
app.get('/api/mcp/download', (req, res) => {
  const mcpAssetsDir = path.join(__dirname, 'MCP', 'assets');
  if (!fs.existsSync(mcpAssetsDir)) {
    return res.status(404).json({ error: 'MCP assets directory not found' });
  }

  const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  const zipFileName = `mcp-vault-${timestamp}.zip`;
  const zipFilePath = path.join(__dirname, zipFileName);

  exec(`zip -r "${zipFilePath}" "assets"`, { cwd: path.join(__dirname, 'MCP'), timeout: 60000 }, (error) => {
    if (error) {
      console.error('MCP vault zip failed:', error);
      return res.status(500).json({ error: 'Failed to create ZIP package' });
    }

    res.download(zipFilePath, zipFileName, (err) => {
      try {
        if (fs.existsSync(zipFilePath)) fs.unlinkSync(zipFilePath);
      } catch (cleanupErr) {
        console.error('Failed to remove temporary zip:', cleanupErr);
      }
    });
  });
});

// Read a specific page's Markdown file content
app.get('/api/tasks/:id/page', (req, res) => {
  const task = tasks.get(req.params.id);
  if (!task) return res.status(404).json({ error: 'Task not found' });
  
  const url = req.query.url;
  const node = task.nodes.get(url);
  if (!node) return res.status(404).json({ error: 'Page not found in task' });

  const filePath = path.join(task.vaultPath, `${node.label}.md`);
  if (fs.existsSync(filePath)) {
    const content = fs.readFileSync(filePath, 'utf-8');
    return res.json({ title: node.label, url, content });
  } else {
    return res.status(404).json({ error: `Markdown file [${node.label}.md] not found on disk` });
  }
});

app.get('/api/tasks/:id', (req, res) => {
  const task = tasks.get(req.params.id);
  if (!task) {
    return res.status(404).json({ error: 'Task not found' });
  }
  res.json({
    id: task.id,
    seedUrl: task.seedUrl,
    status: task.status,
    startTime: task.startTime,
    endTime: task.endTime,
    vaultPath: task.vaultPath,
    nodesCount: task.nodes.size
  });
});

app.post('/api/tasks/:id/abort', (req, res) => {
  const task = tasks.get(req.params.id);
  if (!task) {
    return res.status(404).json({ error: 'Task not found' });
  }
  task.aborted = true;
  task.status = 'aborted';
  sendTaskEvent(task.id, { type: 'status', data: { status: 'aborted' } });
  res.json({ message: 'Task aborted successfully' });
});

app.get('/api/tasks/:id/stream', (req, res) => {
  const task = tasks.get(req.params.id);
  if (!task) {
    return res.status(404).json({ error: 'Task not found' });
  }

  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders();

  res.write(`data: ${JSON.stringify({ type: 'status', data: { status: task.status } })}\n\n`);
  
  task.nodes.forEach(node => {
    res.write(`data: ${JSON.stringify({ type: 'node-added', data: node })}\n\n`);
  });

  if (task.status === 'completed') {
    const files = fs.existsSync(task.vaultPath) ? fs.readdirSync(task.vaultPath).filter(f => f.endsWith('.md')) : [];
    const labelToUrl = new Map();
    task.nodes.forEach(node => {
      labelToUrl.set(node.label, node.url);
    });

    for (const file of files) {
      const title = file.substring(0, file.length - 3);
      const url = labelToUrl.get(title);
      if (!url) continue;

      try {
        const fileContent = fs.readFileSync(path.join(task.vaultPath, file), 'utf-8');
        const wikilinkRegex = /\[\[(.*?)\]\]/g;
        let linkMatch;
        while ((linkMatch = wikilinkRegex.exec(fileContent)) !== null) {
          const targetTitle = linkMatch[1];
          const targetUrl = labelToUrl.get(targetTitle) || `https://${new URL(url).host}/${targetTitle}`;
          res.write(`data: ${JSON.stringify({ type: 'edge-added', data: { from: url, to: targetUrl } })}\n\n`);
        }
      } catch (err) {}
    }
  }

  task.logs.forEach(log => {
    res.write(`data: ${JSON.stringify({ type: 'log', data: log })}\n\n`);
  });

  task.listeners.push(res);

  req.on('close', () => {
    task.listeners = task.listeners.filter(l => l !== res);
  });
});

// Ban list API endpoints
app.get('/api/banlist', (req, res) => {
  res.json(banlist);
});

app.post('/api/banlist', (req, res) => {
  if (Array.isArray(req.body.banlist)) {
    banlist = req.body.banlist.map(s => s.trim()).filter(s => s.length > 0);
    try {
      fs.writeFileSync(BANLIST_PATH, JSON.stringify(banlist, null, 2), 'utf-8');
      res.json({ success: true, banlist });
    } catch (e) {
      res.status(500).json({ error: 'Failed to write banlist.json' });
    }
  } else {
    res.status(400).json({ error: 'banlist must be an array of strings' });
  }
});

// Promote task vault to MCP knowledge base
app.post('/api/tasks/:id/promote-to-knowledge-base', (req, res) => {
  const task = tasks.get(req.params.id);
  if (!task) {
    return res.status(404).json({ error: 'Task not found' });
  }
  
  if (task.status !== 'completed') {
    return res.status(400).json({ error: 'Task must be completed before promoting to knowledge base' });
  }
  
  if (!fs.existsSync(task.vaultPath)) {
    return res.status(404).json({ error: 'Vault folder not found' });
  }
  
  const mcpAssetsDir = path.join(__dirname, 'MCP', 'assets');
  
  try {
    // Ensure MCP/assets directory exists
    if (!fs.existsSync(mcpAssetsDir)) {
      fs.mkdirSync(mcpAssetsDir, { recursive: true });
    }
    
    // Copy all .md files from task vault to MCP/assets
    const files = fs.readdirSync(task.vaultPath).filter(f => f.endsWith('.md'));
    let copiedCount = 0;
    
    for (const file of files) {
      const srcPath = path.join(task.vaultPath, file);
      const destPath = path.join(mcpAssetsDir, file);
      fs.copyFileSync(srcPath, destPath);
      copiedCount++;
    }
    
    console.log(`Promoted ${copiedCount} files from task ${task.id} to MCP knowledge base`);
    
    // --- Auto hot-reload pipeline ---
    const reloadResults = { mcpIndex: null, autoragIndex: null };

    // Step 1: Rebuild MCP graph index (incremental — no --force)
    const nodePath = '/root/.nvm/versions/node/v24.12.0/bin/node';
    const indexerPath = path.join(__dirname, 'MCP', 'indexer.js');
    exec(`${nodePath} ${indexerPath}`, { cwd: path.join(__dirname, 'MCP'), timeout: 120000 }, (err, stdout, stderr) => {
      if (err) {
        console.error('[Auto-reload] MCP index rebuild failed:', stderr || err.message);
        reloadResults.mcpIndex = 'failed';
      } else {
        console.log('[Auto-reload] MCP index rebuilt successfully');
        reloadResults.mcpIndex = 'success';
      }

      // Step 2: Trigger AutoRAG reindex (POST /reindex)
      try {
        const url = new URL(`${AUTORAG_API_URL}/reindex`);
        const postData = JSON.stringify({});
        const options = {
          hostname: url.hostname,
          port: url.port,
          path: url.pathname,
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(postData) },
          timeout: 300000,
        };
        const apiReq = http.request(options, (apiRes) => {
          let body = '';
          apiRes.on('data', chunk => body += chunk);
          apiRes.on('end', () => {
            try {
              const result = JSON.parse(body);
              reloadResults.autoragIndex = result.success ? 'success' : 'failed';
              console.log(`[Auto-reload] AutoRAG reindex: ${reloadResults.autoragIndex}`, result.method || '');
            } catch (e) {
              reloadResults.autoragIndex = 'failed';
              console.error('[Auto-reload] AutoRAG reindex parse error:', e.message);
            }
          });
        });
        apiReq.on('error', (e) => {
          reloadResults.autoragIndex = 'unreachable';
          console.error('[Auto-reload] AutoRAG API unreachable:', e.message);
        });
        apiReq.on('timeout', () => {
          apiReq.destroy();
          reloadResults.autoragIndex = 'timeout';
        });
        apiReq.write(postData);
        apiReq.end();
      } catch (e) {
        reloadResults.autoragIndex = 'error';
        console.error('[Auto-reload] AutoRAG trigger error:', e.message);
      }
    });

    res.json({
      success: true,
      copiedFiles: copiedCount,
      message: `Copied ${copiedCount} files to MCP/assets. Auto-reload triggered for MCP index + AutoRAG search.`,
      autoReload: 'triggered',
    });
  } catch (e) {
    console.error('Failed to promote to knowledge base:', e);
    res.status(500).json({ error: 'Failed to promote to knowledge base: ' + e.message });
  }
});

// Rebuild MCP index
app.post('/api/mcp/rebuild-index', async (req, res) => {
  const mcpDir = path.join(__dirname, 'MCP');
  
  try {
    // Use nvm node v24 for running the indexer (required for @xenova/transformers)
    const nodePath = '/root/.nvm/versions/node/v24.12.0/bin/node';
    const indexerPath = path.join(mcpDir, 'indexer.js');
    
    exec(`${nodePath} ${indexerPath} --force`, { cwd: mcpDir, timeout: 120000 }, (error, stdout, stderr) => {
      if (error) {
        console.error('Index rebuild failed:', error);
        return res.status(500).json({ error: 'Index rebuild failed: ' + (stderr || error.message) });
      }
      
      res.json({ 
        success: true, 
        message: 'MCP index rebuilt successfully',
        output: stdout
      });
      // Chain: trigger AutoRAG /reindex to sync corpus
      const autoragUrl = process.env.AUTORAG_API_URL || "http://127.0.0.1:8002";
      fetch(`${autoragUrl}/reindex`, { method: "POST" })
        .then(r => r.json())
        .then(d => console.log("[rebuild-index] AutoRAG reindex:", d.success ? "ok" : "skipped"))
        .catch(e => console.error("[rebuild-index] AutoRAG reindex failed:", e.message));
    });
  } catch (e) {
    console.error('Failed to rebuild index:', e);
    res.status(500).json({ error: 'Failed to rebuild index: ' + e.message });
  }
});

app.use(express.static(path.join(__dirname, 'public')));

loadCompletedTasksFromDisk();

// Handle process termination gracefully with a timeout
function handleShutdown(signal) {
  console.log(`Received ${signal}. Shutting down gracefully...`);
  
  // Force exit if graceful shutdown hangs
  setTimeout(() => {
    console.error(`Graceful shutdown timed out on ${signal}. Forcing exit.`);
    process.exit(1);
  }, 5000).unref();

  // Close server
  if (server) {
    server.close(() => {
      console.log('HTTP server closed.');
      process.exit(0);
    });
  } else {
    process.exit(0);
  }
}

process.on('SIGTERM', () => handleShutdown('SIGTERM'));
process.on('SIGINT', () => handleShutdown('SIGINT'));

const server = app.listen(PORT, '0.0.0.0', () => {
  console.log('================================================');
  console.log(`⚕ Networker Server running on http://0.0.0.0:${PORT}`);
  console.log('================================================');
});

// Helper function to post-process standard markdown links into Obsidian Wikilinks
function convertMarkdownLinksToWikilinks(markdown, urlToTitleMap, currentUrl, urlToImageUrlMap = new Map()) {
  const base = currentUrl;
  
  // 1. First, replace hyperlinked images: [![alt](imgUrl)](linkUrl)
  markdown = markdown.replace(/\[\!\[([^\]]*)\]\(([^)]+)\)\]\(([^)]+)\)/g, (match, alt, imgUrl, linkUrl) => {
    try {
      const absoluteLinkUrl = new URL(linkUrl, base);
      if (absoluteLinkUrl.protocol === 'http:' || absoluteLinkUrl.protocol === 'https:') {
        const normalizedTarget = normalizeUrl(absoluteLinkUrl.toString());
        if (urlToImageUrlMap.has(normalizedTarget)) {
          const finalImgUrl = urlToImageUrlMap.get(normalizedTarget);
          return `![${alt}](${finalImgUrl})`;
        }
        const targetTitle = getTitleForUrl(normalizedTarget, urlToTitleMap);
        if (targetTitle) {
          return `[![${alt}](${imgUrl})]([[${targetTitle}]])`;
        } else {
          return `[![${alt}](${imgUrl})](${absoluteLinkUrl.toString()})`;
        }
      }
    } catch (e) {}
    return match;
  });

  // 2. Then, replace normal links: [text](href)
  return markdown.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (match, text, href) => {
    try {
      const absoluteUrl = new URL(href, base);
      if (absoluteUrl.protocol === 'http:' || absoluteUrl.protocol === 'https:') {
        const normalizedTarget = normalizeUrl(absoluteUrl.toString());
        
        if (urlToImageUrlMap.has(normalizedTarget)) {
          const imgUrl = urlToImageUrlMap.get(normalizedTarget);
          return `![${text}](${imgUrl})`;
        }

        const targetTitle = getTitleForUrl(normalizedTarget, urlToTitleMap);
        if (targetTitle) {
          return `[[${targetTitle}${text !== targetTitle ? '|' + text : ''}]]`;
        } else {
          // If the page was not crawled, rewrite to absolute web link to prevent Obsidian from creating empty nodes
          return `[${text}](${absoluteUrl.toString()})`;
        }
      }
    } catch (e) {}
    return match;
  });
}
