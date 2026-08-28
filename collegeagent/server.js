#!/usr/bin/env node
/**
 * CollegeAgent AI Backend — Express server (port 4093)
 *
 * Features:
 *   - User login / registration
 *   - Chat session CRUD
 *   - Streaming AI chat via DeepSeek (SSE)
 *   - MCP tool-calling (memory-mcp) for per-user persistent memory
 *   - Memory REST endpoints for frontend display / editing
 */

import express from 'express';
import multer from 'multer';
import { parseDocumentToMarkdown } from './doc_parser.js';
import { setupPersonalVaultRoutes } from './personal_vault_routes.js';
import cors from 'cors';
import { v4 as uuidv4 } from 'uuid';
import { readFileSync, writeFileSync, existsSync, watchFile, mkdirSync, promises as fsPromises } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { google } from 'googleapis';
import TurndownService from 'turndown';
import 'dotenv/config';

import McpManager from './mcp_manager.js';

// ─── paths ────────────────────────────────────────────────────────────────────

const __filename = fileURLToPath(import.meta.url);
const __dirname  = path.dirname(__filename);

// ─── config ───────────────────────────────────────────────────────────────────

const PORT              = 4093;
const DEEPSEEK_API_KEY  = process.env.DEEPSEEK_API_KEY || '';
const DEEPSEEK_BASE_URL = 'https://api.deepseek.com';
const DEEPSEEK_MODEL    = 'deepseek-chat';
const NODE_BIN          = '/root/.nvm/versions/node/v24.12.0/bin/node';

// ─── persistent data stores ──────────────────────────────────────────────────

const DATA_FILE = path.join(__dirname, 'data.json');

const users    = new Map();
const sessions = new Map();
const messages = new Map();
const _sourceRegistries = new Map();
const activeChatStreams = new Map(); // sessionId -> { abortStream: Function|null, isStopped: boolean }
let seqCounter = 0;

// Load persisted data on startup
function loadData() {
  try {
    if (existsSync(DATA_FILE)) {
      const raw = JSON.parse(readFileSync(DATA_FILE, 'utf-8'));
      if (raw.users)    Object.entries(raw.users).forEach(([k, v]) => users.set(k, v));
      if (raw.sessions) Object.entries(raw.sessions).forEach(([k, v]) => sessions.set(k, v));
      if (raw.messages) Object.entries(raw.messages).forEach(([k, v]) => messages.set(k, v));
      if (raw.sourceRegistries) Object.entries(raw.sourceRegistries).forEach(([k, v]) => _sourceRegistries.set(k, v));
      if (raw.seqCounter) seqCounter = raw.seqCounter;
      console.log(`💾 Loaded ${sessions.size} sessions, ${Object.values(raw.messages || {}).flat().length} messages from disk`);
    }
  } catch (e) {
    console.error('Failed to load data:', e.message);
  }
}

// Debounced save (writes at most once per second)
let _saveTimer = null;
function saveData() {
  if (_saveTimer) return;
  _saveTimer = setTimeout(() => {
    _saveTimer = null;
    try {
      const data = {
        users: Object.fromEntries(users),
        sessions: Object.fromEntries(sessions),
        messages: Object.fromEntries(messages),
        sourceRegistries: Object.fromEntries(_sourceRegistries),
        seqCounter,
      };
      writeFileSync(DATA_FILE, JSON.stringify(data), 'utf-8');
    } catch (e) {
      console.error('Failed to save data:', e.message);
    }
  }, 1000);
}

function pushMsg(sessionId, role, text, meta, userId) {
  if (!messages.has(sessionId)) messages.set(sessionId, []);
  const arr = messages.get(sessionId);
  const now = new Date().toISOString();
  const msg = {
    id: uuidv4(),
    sessionId,
    role,
    text,
    timestamp: now,
    seq: ++seqCounter,
  };
  if (meta) msg.meta = meta;
  arr.push(msg);
  let s = sessions.get(sessionId);
  if (!s) {
    // Session metadata was lost (e.g. deleted while async tool chain was still running).
    // Auto-recover: rebuild a minimal session entry so the message is never truly orphaned.
    const resolvedUserId = userId
      || arr.find(m => m.role === 'user')?.userId
      || (meta?.toolCalls?.[0]?.args?.userId)
      || 'unknown';
    console.warn(`[pushMsg] Session ${sessionId} not found in index — auto-recovering orphaned session for user ${resolvedUserId}`);
    s = {
      id: sessionId,
      sessionId,
      userId: resolvedUserId,
      title: text.slice(0, 50) || 'Recovered Session',
      createdAt: arr[0]?.timestamp || now,
      lastActive: now,
      lastMessage: text.slice(0, 120),
      latestAssistant: role === 'assistant' ? text.slice(0, 120) : null,
      msgCount: arr.length,
    };
    sessions.set(sessionId, s);
  } else {
    s.lastActive = now;
    s.lastMessage = text.slice(0, 120);
    s.msgCount = arr.length;
    if (role === 'assistant') s.latestAssistant = text.slice(0, 120);
  }
  saveData();
  return msg;
}

// ─── auto title generation ──────────────────────────────────────────────────

async function generateTitle(sessionId, userText) {
  try {
    const resp = await fetch(`${DEEPSEEK_BASE_URL}/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${DEEPSEEK_API_KEY}`,
      },
      body: JSON.stringify({
        model: DEEPSEEK_MODEL,
        messages: [
          { role: 'system', content: 'Generate a brief chat title (max 8 words) for this conversation. Use the same language as the user. Reply with ONLY the title, no quotes.' },
          { role: 'user', content: userText },
        ],
        stream: false,
      }),
    });
    const data = await resp.json();
    const title = data.choices?.[0]?.message?.content?.trim();
    if (title) {
      const s = sessions.get(sessionId);
      if (s) s.title = title.slice(0, 50);
    }
  } catch (e) {
    console.error('Title generation failed:', e.message);
  }
}

// ─── system prompt (auto-reloads on file change) ─────────────────────────────

const AGENTS_PATH = path.join(__dirname, 'AGENTS.md');
let SYSTEM_PROMPT = 'You are a helpful AI assistant.';

function loadSystemPrompt() {
  if (existsSync(AGENTS_PATH)) {
    const content = readFileSync(AGENTS_PATH, 'utf-8');
    if (content !== SYSTEM_PROMPT) {
      SYSTEM_PROMPT = content;
      console.log(`📄 System prompt ${SYSTEM_PROMPT.length === content.length ? 'loaded' : 'reloaded'} from AGENTS.md (${SYSTEM_PROMPT.length} chars)`);
    }
  }
}

loadSystemPrompt();

// Watch for AGENTS.md changes (poll every 2s) — no restart needed
watchFile(AGENTS_PATH, { interval: 2000 }, () => {
  console.log('🔄 AGENTS.md changed, reloading system prompt...');
  loadSystemPrompt();
});

// ─── MCP Manager ────────────────────────────────────────────────────────────

const mcpManager = new McpManager();

// ─── Source Registry (numeric citation IDs) ────────────────────────────────

// Per-session source registry — resets at the start of each chat request
// so each session has its own sourceIds starting from 1.

function getRegistrySession(sessionId) {
  if (!_sourceRegistries.has(sessionId)) {
    _sourceRegistries.set(sessionId, { counter: 0, registry: [], nodeMap: {}, urlMap: {} });
  }
  return _sourceRegistries.get(sessionId);
}

function registerSource(sessionId, sourceData) {
  const sess = getRegistrySession(sessionId);
  const { title, nodeId, sourceUrl, fullContent, crawledAt } = sourceData;

  if (nodeId && sess.nodeMap[nodeId]) {
    const existing = sess.registry.find(s => s.id === sess.nodeMap[nodeId]);
    if (existing) {
      if (fullContent && fullContent.length > (existing.fullContent || '').length) existing.fullContent = fullContent;
      return existing.id;
    }
  }
  
  const dedupUrl = sourceUrl || null;
  if (dedupUrl && !nodeId && sess.urlMap[dedupUrl]) {
    const existing = sess.registry.find(s => s.id === sess.urlMap[dedupUrl]);
    if (existing) {
      if (fullContent && fullContent.length > (existing.fullContent || '').length) existing.fullContent = fullContent;
      return existing.id;
    }
  }

  sess.counter++;
  const entry = { id: sess.counter, title, nodeId: nodeId || null, sourceUrl: dedupUrl, crawledAt: crawledAt || null, fullContent: fullContent || '' };
  sess.registry.push(entry);
  if (nodeId) sess.nodeMap[nodeId] = entry.id;
  if (dedupUrl && !nodeId) sess.urlMap[dedupUrl] = entry.id;
  
  return entry.id;
}

function getSourceById(sessionId, id) {
  const sess = getRegistrySession(sessionId);
  return sess.registry.find(s => s.id === id) || null;
}

// ─── Citation parsing ─────────────────────────────────────────────────────────

/**
 * Parse compact numeric citations: [1], [1,45], [1,45,62].
 * Same sourceId can appear multiple times with different line ranges.
 * Also supports legacy [Source: title] for backward compatibility.
 * Captures ~300 chars of text BEFORE the marker as context.
 */
function parseCitations(text) {
  const citations = [];
  let idx = 0;

  // Compact format: [1], [2,45], [3,45,62], or [3,45-62] (hyphen range)
  const numRegex = /\[\s*(\d+)(?:\s*,\s*(\d+)(?:\s*[,\-]\s*(\d+))?)?\s*\]/g;
  let match;
  while ((match = numRegex.exec(text)) !== null) {
    const before = text.slice(Math.max(0, match.index - 300), match.index);
    const sourceId = parseInt(match[1], 10);
    let lines = null;
    if (match[2]) {
      const start = parseInt(match[2], 10);
      const end = match[3] ? parseInt(match[3], 10) : start;
      lines = { start: Math.min(start, end), end: Math.max(start, end) };
    }
    citations.push({
      index: ++idx,
      sourceId,
      title: null,
      context: before.trim(),
      lines,
    });
  }

  // If no numeric citations found, try legacy [Source: title] format
  if (citations.length === 0) {
    const legacyRegex = /\[Source:\s*([^\]]+)\]/g;
    while ((match = legacyRegex.exec(text)) !== null) {
      const before = text.slice(Math.max(0, match.index - 300), match.index);
      const raw = match[1].trim();
      let title = raw;
      let lines = null;
      const linesMatch = raw.match(/^(.+?),\s*lines?\s+(\d+)(?:\s*-\s*(\d+))?$/i);
      if (linesMatch) {
        title = linesMatch[1].trim();
        const start = parseInt(linesMatch[2], 10);
        const end = linesMatch[3] ? parseInt(linesMatch[3], 10) : start;
        lines = { start: Math.min(start, end), end: Math.max(start, end) };
      }
      citations.push({
        index: ++idx,
        sourceId: null,
        title,
        context: before.trim(),
        lines,
      });
    }
  }

  return citations;
}

/**
 * Retrieve full content of a graph node across private vaults, public index, or MCP read tool.
 */
async function getFullNodeContent(nodeId, userId) {
  if (!nodeId) return null;
  // 1. Try private vaults
  try {
    const vaultsDir = path.join(__dirname, '..', 'networker', 'MCP', 'private_vaults');
    if (userId) {
      const uIndexPath = path.join(vaultsDir, userId, 'index.json');
      if (existsSync(uIndexPath)) {
        const priv = JSON.parse(await fsPromises.readFile(uIndexPath, 'utf-8'));
        if (priv.nodes && priv.nodes[nodeId]?.content) {
          return priv.nodes[nodeId].content;
        }
      }
    }
    if (existsSync(vaultsDir)) {
      const uDirs = await fsPromises.readdir(vaultsDir);
      for (const uDir of uDirs) {
        const uIndexPath = path.join(vaultsDir, uDir, 'index.json');
        if (existsSync(uIndexPath)) {
          const priv = JSON.parse(await fsPromises.readFile(uIndexPath, 'utf-8'));
          if (priv.nodes && priv.nodes[nodeId]?.content) {
            return priv.nodes[nodeId].content;
          }
        }
      }
    }
  } catch (e) {}

  // 2. Try public index
  try {
    const publicIndexPath = path.join(__dirname, '..', 'networker', 'MCP', 'index.json');
    if (existsSync(publicIndexPath)) {
      const pub = JSON.parse(await fsPromises.readFile(publicIndexPath, 'utf-8'));
      if (pub.nodes && pub.nodes[nodeId]?.content) {
        return pub.nodes[nodeId].content;
      }
    }
  } catch (e) {}

  // 3. Fallback to mcpManager callTool('read')
  try {
    const result = await mcpManager.callTool('read', { nodeId, userId });
    if (result) {
      const parsed = JSON.parse(result);
      if (parsed.content) return parsed.content;
    }
  } catch (e) {}

  return null;
}

/**
 * Extract specific lines or relevant slide/paragraph from source content.
 */
function extractSnippet(content, lines, context) {
  if (!content) return null;

  const allLines = content.split('\n');
  const hasLineNumbers = allLines.some(l => /^\s*\d+\|/.test(l));

  // If explicit line numbers are present in the text (from read tool)
  if (lines && hasLineNumbers) {
    const start = Math.max(0, lines.start - 1); // 0-indexed
    const end = Math.min(allLines.length, lines.end);
    const extracted = allLines.slice(start, end)
      .map(l => l.replace(/^\s*\d+\|/, ''))  // strip line number prefix
      .join('\n')
      .trim();
    if (extracted && extracted.length > 5) return extracted.slice(0, 800);
  }

  // If content has markdown slide/page dividers (e.g. PPTX / PDF)
  const slides = content.split(/\n\s*---\s*\n/).map(s => s.trim()).filter(Boolean);
  if (lines && slides.length > 1) {
    // Model might have cited slide numbers [1, 24]
    const slideIdx = lines.start - 1;
    if (slideIdx >= 0 && slideIdx < slides.length) {
      const slideText = slides[slideIdx].replace(/^\s*\d+\|/gm, '').trim();
      if (slideText.length > 10) return slideText.slice(0, 800);
    }
  }

  // Semantic context matching across full document (slides, paragraphs, sections)
  if (context) {
    const relevant = findRelevantParagraph(content, context);
    if (relevant) return relevant;
  }

  // Fallback to line slice
  if (lines) {
    const start = Math.max(0, lines.start - 1);
    const end = Math.min(allLines.length, lines.end);
    const extracted = allLines.slice(start, end)
      .map(l => l.replace(/^\s*\d+\|/, ''))
      .join('\n')
      .trim();
    if (extracted && extracted.length > 5) return extracted.slice(0, 800);
  }

  // Last resort: first 500 chars (strip prefixes)
  return content.split('\n')
    .map(l => l.replace(/^\s*\d+\|/, ''))
    .join('\n')
    .trim()
    .slice(0, 500);
}

/**
 * Find the most relevant paragraph or slide given a context string (supports English, CJK, numbers).
 */
function findRelevantParagraph(numberedContent, context) {
  // Strip line number prefixes first
  const cleanContent = numberedContent.split('\n')
    .map(l => l.replace(/^\s*\d+\|/, ''))
    .join('\n');

  if (!context) return cleanContent.slice(0, 500);

  const stopWords = new Set([
    'the', 'a', 'an', 'is', 'are', 'was', 'were', 'and', 'or', 'of', 'to', 'in', 'for', 'on', 'at', 'by', 'with', 'as', 'that', 'this', 'it', 'be', 'has', 'had', 'not', 'but', 'from', 'will', 'can',
    '这是', '我们', '你们', '他们', '这个', '那个', '因为', '所以', '以及', '或者', '还有', '进行', '可以', '需要', '如果', '之后', '通过', '关于'
  ]);
  
  // Extract alphanumeric & CJK terms
  const tokens = context.toLowerCase().match(/[\w\u4e00-\u9fa5]{2,}/g) || [];
  const contextWords = new Set(tokens.filter(w => !stopWords.has(w)));
  
  // Extract continuous CJK 2-grams for high-fidelity Chinese fuzzy matching
  const cjkMatches = context.match(/[\u4e00-\u9fa5]+/g) || [];
  for (const cjk of cjkMatches) {
    if (cjk.length >= 2) {
      for (let i = 0; i < cjk.length - 1; i++) {
        contextWords.add(cjk.substring(i, i + 2));
      }
    }
  }

  if (contextWords.size === 0) return cleanContent.slice(0, 500);

  // Split into slides, sections, or paragraphs
  const paragraphs = cleanContent
    .split(/\n\s*---\s*\n|\n\n+|(?=\n##+\s)/)
    .map(p => p.trim())
    .filter(p => p.length > 20);

  if (paragraphs.length === 0) return cleanContent.slice(0, 500);

  let bestParagraph = paragraphs[0];
  let bestScore = 0;

  for (const para of paragraphs) {
    const paraLower = para.toLowerCase();
    let score = 0;
    for (const word of contextWords) {
      if (paraLower.includes(word)) {
        score += (word.length >= 4 ? 3 : (word.length >= 2 ? 1.5 : 1));
      }
    }
    if (score > bestScore) {
      bestScore = score;
      bestParagraph = para;
    }
  }

  return bestParagraph.trim().slice(0, 700);
}

/**
 * Parse Source URL and Crawled At from node content metadata.
 * Format: "- **Source URL**: [text](url)\n- **Crawled At**: timestamp"
 */
function parseNodeMeta(content) {
  const meta = { sourceUrl: null, crawledAt: null };
  if (!content) return meta;
  const urlMatch = content.match(/\*\*Source URL\*\*:\s*\[.*?\]\((.+?)\)/);
  if (urlMatch) meta.sourceUrl = urlMatch[1];
  const crawlMatch = content.match(/\*\*Crawled At\*\*:\s*(.+)/);
  if (crawlMatch) meta.crawledAt = crawlMatch[1].trim();
  return meta;
}

/**
 * Resolve citations using the source registry (numeric IDs) with fallback to legacy title lookup.
 * Returns array of { index, title, nodeId, snippet, sourceUrl, crawledAt } objects.
 */
async function resolveCitations(citations, citationSources, userId, sessionId) {
  const resolved = [];

  for (const c of citations) {
    let source = null;

    // 1. Try numeric sourceId from registry
    if (c.sourceId) {
      source = getSourceById(sessionId, c.sourceId);
    }

    // 2. Legacy fallback: lookup by title
    if (!source && c.title) {
      const key = c.title.toLowerCase();
      // Try knowledge graph
      const node = await mcpManager.lookupNodeByTitle(c.title);
      if (node?.nodeId) {
        const nodeMeta = parseNodeMeta(node.fullContent);
        source = {
          nodeId: node.nodeId,
          title: node.title || c.title,
          fullContent: node.fullContent || '',
          sourceUrl: nodeMeta.sourceUrl,
          crawledAt: nodeMeta.crawledAt,
        };
      } else {
        // Try web_search sources
        const webMatch = citationSources.find(s => s.title.toLowerCase() === key);
        if (webMatch) {
          source = {
            nodeId: null,
            title: webMatch.title,
            fullContent: webMatch.description || webMatch.snippet || '',
            sourceUrl: webMatch.url,
            crawledAt: null,
          };
        }
      }
    }

    if (!source) {
      // Unresolvable citation — still include it with minimal info
      resolved.push({
        index: c.index,
        title: c.title || `Source ${c.sourceId}`,
        nodeId: null,
        snippet: null,
        sourceUrl: null,
        crawledAt: null,
      });
      continue;
    }

    // Fetch full node content if source only had a short snippet from search
    if (source.nodeId && (!source.fullContent || source.fullContent.length < 3000)) {
      const fullDoc = await getFullNodeContent(source.nodeId, userId);
      if (fullDoc && fullDoc.length > (source.fullContent || '').length) {
        source.fullContent = fullDoc;
      }
    }

    // Extract snippet: exact lines, slide index, or context-matched semantic paragraph
    const snippet = extractSnippet(source.fullContent, c.lines, c.context);

    resolved.push({
      index: c.index,
      title: source.title,
      nodeId: source.nodeId,
      snippet: snippet || null,
      sourceUrl: source.sourceUrl,
      crawledAt: source.crawledAt,
    });
  }

  return resolved;
}

// ─── SSE helpers ──────────────────────────────────────────────────────────────

function sseEvent(res, event, data) {
  res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}

// ─── Express app ──────────────────────────────────────────────────────────────

const app = express();
app.use(cors());
app.use(express.json({ limit: '2mb' }));
setupPersonalVaultRoutes(app);

// ── POST /api/login ──────────────────────────────────────────────────────────

app.post('/api/login', (req, res) => {
  const { username } = req.body;
  if (!username || !username.trim()) return res.status(400).json({ error: 'username required' });

  let user = users.get(username);
  if (!user) {
    user = { userId: uuidv4(), username: username.trim() };
    users.set(username, user);
    saveData();
  }
  res.json(user);
});

// ── GET /api/sessions ─────────────────────────────────────────────────────────

app.get('/api/sessions', (req, res) => {
  const { userId, debug } = req.query;
  if (debug === 'all') {
    const list = [...sessions.values()]
      .sort((a, b) => (b.lastActive || b.createdAt).localeCompare(a.lastActive || a.createdAt))
      .map(s => ({ ...s, id: s.sessionId || s.id }));
    return res.json(list);
  }
  const list = [...sessions.values()]
    .filter((s) => s.userId === userId)
    .sort((a, b) => (b.lastActive || b.createdAt).localeCompare(a.lastActive || a.createdAt))
    .map(s => ({ ...s, id: s.sessionId || s.id }));
  res.json(list);
});

app.post('/api/sessions', (req, res) => {
  const { userId } = req.body;
  if (!userId) return res.status(400).json({ error: 'userId required' });

  const sessionId = uuidv4();
  const session = {
    id: sessionId,
    sessionId,
    userId,
    title: 'New Session',
    createdAt: new Date().toISOString(),
    lastActive: new Date().toISOString(),
  };
  sessions.set(sessionId, session);
  messages.set(sessionId, []);
  saveData();
  res.status(201).json(session);
});

// ── POST /api/sessions/fork ──────────────────────────────────────────────────

app.post('/api/sessions/fork', (req, res) => {
  const { userId, sessionId } = req.body;
  if (!userId || !sessionId) {
    return res.status(400).json({ error: 'userId and sessionId required' });
  }

  const parentSession = sessions.get(sessionId);
  if (!parentSession) {
    return res.status(404).json({ error: 'Source session not found' });
  }

  const newSessionId = uuidv4();
  const rootId = parentSession.parentId || parentSession.id || sessionId;
  const now = new Date().toISOString();

  // Clone messages
  const srcMsgs = messages.get(sessionId) || [];
  const clonedMsgs = srcMsgs.map((m) => ({
    ...m,
    id: uuidv4(),
    sessionId: newSessionId,
    seq: ++seqCounter,
  }));
  messages.set(newSessionId, clonedMsgs);

  // Clone source registry if exists
  if (_sourceRegistries.has(sessionId)) {
    const srcReg = _sourceRegistries.get(sessionId);
    try {
      _sourceRegistries.set(newSessionId, JSON.parse(JSON.stringify(srcReg)));
    } catch (_) {}
  }

  const session = {
    id: newSessionId,
    sessionId: newSessionId,
    userId,
    parentId: rootId,
    title: parentSession.title ? `${parentSession.title} (Fork)` : 'Forked Session',
    status: 'active',
    createdAt: now,
    lastActive: now,
    pinned: false,
    lastMessage: parentSession.lastMessage || null,
    latestAssistant: parentSession.latestAssistant || null,
    msgCount: clonedMsgs.length,
  };

  sessions.set(newSessionId, session);
  saveData();
  res.status(201).json(session);
});

// ── GET /api/vault/download/:userId ──────────────────────────────────────────

app.get('/api/vault/download/:userId', (req, res) => {
  const { userId } = req.params;
  const vaultPath = path.join(__dirname, '../networker/MCP/private_vaults', userId, 'index.json');
  if (!existsSync(vaultPath)) {
    return res.status(404).json({ error: 'Vault not found' });
  }
  res.download(vaultPath, `private_vault_${userId}.json`);
});


// ── GET /api/messages ─────────────────────────────────────────────────────────

app.get('/api/messages', (req, res) => {
  const { sessionId } = req.query;
  res.json(messages.get(sessionId) || []);
});

// ── POST /api/chat/stop  (Stop current generating session) ───────────────────

app.post('/api/chat/stop', (req, res) => {
  const { sessionId } = req.body;
  if (!sessionId) {
    return res.status(400).json({ error: 'sessionId required' });
  }
  const streamState = activeChatStreams.get(sessionId);
  if (streamState) {
    streamState.isStopped = true;
    if (streamState.abortStream) {
      try { streamState.abortStream(); } catch (e) {}
    }
    console.log(`🛑 [Chat] Stop requested for session: ${sessionId}`);
    return res.json({ success: true, message: 'Stop signal received' });
  }
  res.json({ success: true, message: 'No active stream found' });
});

// ── POST /api/chat  (SSE streaming) ──────────────────────────────────────────

app.post('/api/chat', async (req, res) => {
  const { userId, sessionId, text } = req.body;
  if (!userId || !sessionId || !text) {
    return res.status(400).json({ error: 'userId, sessionId, text required' });
  }
  if (!sessions.has(sessionId)) {
    return res.status(404).json({ error: 'session not found' });
  }

  // Track active stream state for stop requests
  const streamState = {
    isStopped: false,
    abortStream: null,
  };
  activeChatStreams.set(sessionId, streamState);
  let done = false;

  res.on('close', () => {
    if (!done && !res.writableEnded) {
      streamState.isStopped = true;
      if (streamState.abortStream) {
        try { streamState.abortStream(); } catch (e) {}
      }
    }
  });

  // save user message
  pushMsg(sessionId, 'user', text, null, userId);

  // Auto-generate title for first message in session
  const sessMsgs = messages.get(sessionId) || [];
  const userMsgCount = sessMsgs.filter((m) => m.role === 'user').length;
  if (userMsgCount === 1) {
    setTimeout(() => generateTitle(sessionId, text), 5000); // delay title generation to avoid concurrent API hits
  }

  // SSE headers
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no');
  res.flushHeaders();

  let assistantText = '';
  // Collect all tool calls + intermediate texts for persistence
  const allToolCalls = [];  // { name, args, result, intermediateText }
  // Collect web_search results as citable sources (legacy fallback)
  const citationSources = [];  // { title, url, description, snippet }

  try {
    // Immediately send a thinking indicator so the UI doesn't look dead during async operations like memory fetching
    sseEvent(res, 'token', { content: '🤔 正在思考中...\n\n' });

    // build message array with memory injected into system prompt
    const history = messages.get(sessionId) || [];
    const memoryContent = (await mcpManager.getMemory(userId)) || '';
    const { localTime, timeZoneOffset, timeZoneName } = req.body;
    let userTimeStr = new Date().toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' });
    if (localTime) {
      try {
        const userDate = new Date(localTime);
        const days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
        const dayOfWeek = days[userDate.getDay()];
        const year = userDate.getFullYear();
        const month = String(userDate.getMonth() + 1).padStart(2, '0');
        const date = String(userDate.getDate()).padStart(2, '0');
        const hours = String(userDate.getHours()).padStart(2, '0');
        const mins = String(userDate.getMinutes()).padStart(2, '0');
        const secs = String(userDate.getSeconds()).padStart(2, '0');
        const tzInfo = timeZoneName ? ` [${timeZoneName}]` : (timeZoneOffset !== undefined ? ` (Offset: ${timeZoneOffset} mins)` : '');
        userTimeStr = `${year}-${month}-${date} ${hours}:${mins}:${secs} (${dayOfWeek})${tzInfo}`;
      } catch (e) {
        userTimeStr = String(localTime);
      }
    }
    console.log(`🕒 User Time: ${userTimeStr} (from client localTime: ${localTime || 'none'})`);
    
    const sessReg = _sourceRegistries.has(sessionId) ? _sourceRegistries.get(sessionId) : { registry: [] };
    let routingTableText = '';
    if (sessReg.registry.length > 0) {
      routingTableText = '\n\n## Current Session Source Routing Table\n\n' + 
        sessReg.registry.map(s => {
          if (s.rawMeta) return `[${s.id}] ` + JSON.stringify(s.rawMeta);
          return `[${s.id}] ${s.title}`;
        }).join('\n') + 
        '\n\n*Note: Every factual claim MUST be cited with the numeric source ID and EXACT line numbers (e.g., [1, 45-62] or [2, 12]). Text aliases like [syllabus 103] or [BIO, 36] and bare citations like [1] are strictly forbidden. The first value in brackets MUST be the numeric ID (e.g. [1, 103]).*';
    }

    const fullSystemPrompt = SYSTEM_PROMPT + '\n\n## Current User Time\n\n' + userTimeStr + '\n\n## Current User Memory\n\n' + memoryContent + routingTableText;
    const apiMessages = [
      { role: 'system', content: fullSystemPrompt },
      ...history.map((m) => ({ role: m.role, content: m.text })),
    ];

    let lastUsage = null;

    while (!done) {
      if (streamState.isStopped) {
        console.log(`🛑 [Chat] Session ${sessionId} stopped by user before LLM call.`);
        done = true;
        break;
      }

      // ── call DeepSeek with streaming + idle timeout (AGENTS.md §5.C) ──
      const streamAbort = new AbortController();
      streamState.abortStream = () => {
        try { streamAbort.abort(); } catch (_) {}
      };

      let idleTimer = setTimeout(() => {
        try { streamAbort.abort(); } catch (_) {}
      }, 30_000);
      const resetIdleTimer = () => {
        clearTimeout(idleTimer);
        idleTimer = setTimeout(() => {
          try { streamAbort.abort(); } catch (_) {}
        }, 30_000);
      };

      let resp;
      try {
        resp = await fetch(`${DEEPSEEK_BASE_URL}/chat/completions`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${DEEPSEEK_API_KEY}`,
          },
          body: JSON.stringify({
            model: DEEPSEEK_MODEL,
            messages: apiMessages,
            tools: mcpManager.getAllTools(),
            stream: true,
            stream_options: { include_usage: true },
          }),
          signal: streamAbort.signal,
        });
      } catch (err) {
        clearTimeout(idleTimer);
        streamState.abortStream = null;
        if (streamState.isStopped || streamAbort.signal.aborted) {
          console.log(`🛑 [Chat] DeepSeek fetch aborted for session ${sessionId}`);
          done = true;
          break;
        }
        throw err;
      }

      if (!resp.ok) {
        clearTimeout(idleTimer);
        streamState.abortStream = null;
        const errBody = await resp.text();
        throw new Error(`DeepSeek ${resp.status}: ${errBody}`);
      }

      // ── consume stream, collect content + tool_calls ──
      let buf = '';
      const reader = resp.body.getReader();
      const dec = new TextDecoder();
      let streamContent = '';
      let toolCallsMap = {};          // index → { id, type, function: { name, arguments } }
      let finishReason = null;

      try {
        while (true) {
          const { value, done: rDone } = await reader.read();
          if (rDone) break;
          resetIdleTimer();
          buf += dec.decode(value, { stream: true });

          const parts = buf.split('\n\n');
          buf = parts.pop() || '';

          for (const part of parts) {
            const line = part.trim();
            if (!line.startsWith('data: ')) continue;
            const payload = line.slice(6);
            if (payload === '[DONE]') continue;
            try {
              const json = JSON.parse(payload);
              if (json.usage) {
                lastUsage = json.usage;
              }
              const choice = json.choices?.[0];
              if (!choice) continue;
              const delta = choice.delta;

              // collect text content
              if (delta?.content) {
                streamContent += delta.content;
                sseEvent(res, 'token', { content: delta.content });
              }

              // collect tool_calls deltas
              if (delta?.tool_calls) {
                for (const tc of delta.tool_calls) {
                  const idx = tc.index;
                  if (!toolCallsMap[idx]) {
                    toolCallsMap[idx] = {
                      id: tc.id || '',
                      type: tc.type || 'function',
                      function: { name: '', arguments: '' },
                    };
                  }
                  if (tc.id) toolCallsMap[idx].id = tc.id;
                  if (tc.function?.name) toolCallsMap[idx].function.name += tc.function.name;
                  if (tc.function?.arguments) toolCallsMap[idx].function.arguments += tc.function.arguments;
                }
              }

              if (choice.finish_reason) finishReason = choice.finish_reason;
            } catch { /* skip malformed chunk */ }
          }
        }
      } catch (err) {
        if (streamState.isStopped || streamAbort.signal.aborted) {
          console.log(`🛑 [Chat] Stream reader aborted for session ${sessionId}`);
          assistantText = streamContent;
          done = true;
          break;
        }
        throw err;
      } finally {
        clearTimeout(idleTimer);
        streamState.abortStream = null;
        try { reader.cancel().catch(() => {}); } catch { /* ignore */ }
      }

      if (streamState.isStopped) {
        assistantText = streamContent;
        done = true;
        break;
      }

      // ── handle tool calls ──
      const toolCallList = Object.values(toolCallsMap);
      if (finishReason === 'tool_calls' && toolCallList.length > 0) {
        // Send intermediate text (AI reasoning before tool calls) to frontend
        if (streamContent && streamContent.trim()) {
          sseEvent(res, 'intermediate_text', { content: streamContent });
        }

        // push assistant message with tool_calls into context
        apiMessages.push({
          role: 'assistant',
          content: streamContent || null,
          tool_calls: toolCallList,
        });

        // execute each tool
        for (const tc of toolCallList) {
          const fnName = tc.function.name;
          let fnArgs = {};
          try { fnArgs = JSON.parse(tc.function.arguments); } catch { /* ignore */ }
          fnArgs.userId = userId;  // enforce userId
          fnArgs.sessionId = sessionId; // enforce sessionId

          // ── Translate sourceId → nodeId for read/expand ──
          if (fnName === 'read' || fnName === 'expand') {
            // For expand: if url is provided, skip nodeId translation — pass through directly
            if (fnName === 'expand' && fnArgs.url != null) {
              // expand(url) mode — no sourceId/nodeId needed
            } else if (fnArgs.sourceId != null) {
              // Agent correctly sent sourceId — translate to nodeId
              const srcEntry = getSourceById(sessionId, Number(fnArgs.sourceId));
              if (srcEntry?.nodeId) {
                fnArgs.nodeId = srcEntry.nodeId;
              } else {
                const errMsg = JSON.stringify({
                  error: `sourceId ${fnArgs.sourceId} not found. Use sourceIds from previous search/read/expand results.`,
                });
                sseEvent(res, 'tool_start', { name: fnName, args: { sourceId: fnArgs.sourceId } });
                sseEvent(res, 'tool_end', { name: fnName, result: errMsg, duration: 0 });
                apiMessages.push({ role: 'tool', tool_call_id: tc.id, content: errMsg });
                allToolCalls.push({ name: fnName, args: fnArgs, result: errMsg, intermediateText: null, duration: 0 });
                continue;
              }
              delete fnArgs.sourceId;
            } else if (fnArgs.nodeId != null) {
              // Agent sent nodeId directly (schema bypass) — accept it as fallback
            } else {
              const errMsg = JSON.stringify({
                error: fnName === 'expand'
                  ? 'Missing sourceId or url. Call expand(sourceId) or expand(url) — use a sourceId from previous results, or a URL from web_search.'
                  : 'Missing sourceId. Call read(sourceId) using a sourceId from previous results.',
              });
              sseEvent(res, 'tool_start', { name: fnName, args: fnArgs });
              sseEvent(res, 'tool_end', { name: fnName, result: errMsg, duration: 0 });
              apiMessages.push({ role: 'tool', tool_call_id: tc.id, content: errMsg });
              allToolCalls.push({ name: fnName, args: fnArgs, result: errMsg, intermediateText: null, duration: 0 });
              continue;
            }
          }

          const t0 = Date.now();
          sseEvent(res, 'tool_start', { name: fnName, args: fnArgs });

          fnArgs.userId = userId;
          const result = await mcpManager.callTool(fnName, fnArgs);
          const duration = Date.now() - t0;

          // ── Process result: register sources, inject sourceIds, strip nodeIds ──
          let resultForAgent = result || '';
          if (result && (fnName === 'search' || fnName === 'read' || fnName === 'web_search' || fnName === 'expand' || fnName === 'get_page_content' || fnName === 'get_recent_emails' || fnName === 'get_syllabus' || fnName === 'get_announcement_detail' || fnName === 'get_assignment_detail' || fnName === 'get_discussion_detail' || fnName === 'read_file_content')) {
            try {
              const parsed = JSON.parse(result);

              // Helper: register outbound links as sources and replace nodeId with sourceId
              const processOutboundLinks = (links) => {
                if (!Array.isArray(links)) return [];
                return links.map(link => {
                  const srcId = link.nodeId ? registerSource(sessionId, {
                    title: link.title || '',
                    nodeId: link.nodeId,
                    sourceUrl: null,
                    crawledAt: null,
                    fullContent: '',
                  }) : null;
                  return {
                    title: link.title || '',
                    url: link.url,
                    display: link.display,
                    sourceId: srcId,
                  };
                });
              };

              if ((fnName === 'search' || fnName === 'web_search' || fnName === 'expand' || fnName === 'get_recent_emails') && parsed.results && Array.isArray(parsed.results)) {
                if (fnName === 'search') {
                  parsed.notice = 'search returns only short preview snippets. You MUST call read(sourceId) on relevant result(s) to fetch the full document and line numbers before answering.';
                }
                for (const r of parsed.results) {
                  // Prefer crawled title over Brave snippet title (more accurate)
                  const displayTitle = r.crawlTitle || r.title || '';
                                    const srcId = registerSource(sessionId, {
                    title: displayTitle,
                    nodeId: r.nodeId || null,
                    sourceUrl: r.sourceUrl || r.source_url || r.url || null,
                    crawledAt: null,
                    fullContent: r.content || r.snippet || r.description || '',
                                      });
                  r.sourceId = srcId;
                  r.title = displayTitle; // update title for agent
                  if (fnName === 'search') {
                    const preview = (r.content || r.snippet || '').replace(/^\s*\d+\|/gm, '').trim();
                    r.snippet = preview.slice(0, 250) + (preview.length > 250 ? '... [Call read(sourceId) for full text]' : '');
                    delete r.content;
                  }
                  // Process outbound links if present
                  if (r.outboundLinks) {
                    r.outboundLinks = processOutboundLinks(r.outboundLinks);
                  }
                  delete r.nodeId;
                  delete r.inGraph; // web_search internal field
                }
              } else if (fnName === 'get_syllabus' || fnName === 'get_announcement_detail' || fnName === 'get_assignment_detail' || fnName === 'get_discussion_detail' || fnName === 'read_file_content') {
                                const srcId = registerSource(sessionId, {
                  title: parsed.title || fnName,
                  nodeId: null,
                  sourceUrl: parsed.html_url || null,
                  fullContent: parsed.numbered_content || parsed.syllabus_markdown || parsed.description || parsed.message || '',
                                  });
                parsed.sourceId = srcId;
              } else if (fnName === 'expand' || fnName === 'get_page_content') {
                if (parsed.neighbors && Array.isArray(parsed.neighbors)) {
                  // NodeId mode: process neighbor nodes
                  for (const n of parsed.neighbors) {
                                        const srcId = registerSource(sessionId, {
                      title: n.title || '',
                      nodeId: n.nodeId || null,
                      sourceUrl: n.sourceUrl || null,
                      crawledAt: null,
                      fullContent: n.content || '',
                                          });
                    n.sourceId = srcId;
                    if (n.outboundLinks) {
                      n.outboundLinks = processOutboundLinks(n.outboundLinks);
                    }
                    delete n.nodeId;
                  }
                  
                  // ALSO register the main node so it can be cited!
                  const nodeMeta = parseNodeMeta(parsed.content || '');
                                    const srcId = registerSource(sessionId, {
                    title: parsed.title || '',
                    nodeId: parsed.nodeId || null,
                    sourceUrl: parsed.sourceUrl || parsed.url || nodeMeta.sourceUrl,
                    crawledAt: nodeMeta.crawledAt,
                    fullContent: parsed.content || '',
                                      });
                  parsed.sourceId = srcId;
                  if (parsed.outboundLinks) {
                    parsed.outboundLinks = processOutboundLinks(parsed.outboundLinks);
                  }
                  delete parsed.nodeId;

                } else if (parsed.title && (parsed.sourceUrl || parsed.url)) {
                  // URL mode: single crawled page result — register like read
                  const nodeMeta = parseNodeMeta(parsed.content || '');
                                    const srcId = registerSource(sessionId, {
                    title: parsed.title || '',
                    nodeId: null,
                    sourceUrl: parsed.sourceUrl || nodeMeta.sourceUrl,
                    crawledAt: nodeMeta.crawledAt,
                    fullContent: parsed.content || '',
                                      });
                  parsed.sourceId = srcId;
                  if (parsed.outboundLinks) {
                    parsed.outboundLinks = processOutboundLinks(parsed.outboundLinks);
                  }
                }
              } else if (fnName === 'read' && parsed.nodeId) {
                const nodeMeta = parseNodeMeta(parsed.content || '');
                                const srcId = registerSource(sessionId, {
                  title: parsed.title || '',
                  nodeId: parsed.nodeId || null,
                  sourceUrl: nodeMeta.sourceUrl,
                  crawledAt: nodeMeta.crawledAt,
                  fullContent: parsed.content || '',
                                  });
                parsed.sourceId = srcId;
                // Process outbound links
                if (parsed.outboundLinks) {
                  parsed.outboundLinks = processOutboundLinks(parsed.outboundLinks);
                }
                delete parsed.nodeId;
              }

              // Synchronize rawMeta to match the exact tool output seen by the agent
              if ((fnName === 'search' || fnName === 'web_search' || fnName === 'expand' || fnName === 'get_recent_emails') && parsed.results && Array.isArray(parsed.results)) {
                parsed.results.forEach(r => {
                  if (r.sourceId) {
                    const entry = getRegistrySession(sessionId).registry.find(x => x.id === r.sourceId);
                    if (entry) entry.rawMeta = { ...r };
                  }
                });
              } else if (fnName === 'expand' || fnName === 'get_page_content') {
                if (parsed.neighbors && Array.isArray(parsed.neighbors)) {
                  parsed.neighbors.forEach(n => {
                    if (n.sourceId) {
                      const entry = getRegistrySession(sessionId).registry.find(x => x.id === n.sourceId);
                      if (entry) entry.rawMeta = { ...n };
                    }
                  });
                }
                if (parsed.sourceId) {
                  const pCopy = { ...parsed };
                  delete pCopy.neighbors; // Prevent massive nesting in routing table
                  const entry = getRegistrySession(sessionId).registry.find(x => x.id === parsed.sourceId);
                  if (entry) entry.rawMeta = pCopy;
                }
              } else if (parsed.sourceId) {
                const entry = getRegistrySession(sessionId).registry.find(x => x.id === parsed.sourceId);
                if (entry) entry.rawMeta = { ...parsed };
              }

              resultForAgent = JSON.stringify(parsed);
            } catch {
              // If parsing fails, send original result
            }
          }

          // Send CLEANED result via SSE (no nodeIds exposed to agent or frontend)
          sseEvent(res, 'tool_end', { name: fnName, result: resultForAgent, duration });
          apiMessages.push({
            role: 'tool',
            tool_call_id: tc.id,
            content: resultForAgent,
          });

          // Collect web_search results as citable sources
          if (fnName === 'web_search' && result) {
            try {
              const parsed = JSON.parse(result);
              if (parsed.results && Array.isArray(parsed.results)) {
                for (const r of parsed.results) {
                  citationSources.push({
                    title: r.title || '',
                    url: r.url || '',
                    description: r.description || '',
                    snippet: r.snippet || '',
                  });
                }
              }
            } catch { /* ignore parse errors */ }
          }

          let resultToSave = resultForAgent || '';
          try {
            const p = JSON.parse(resultToSave);
            if (p.content && typeof p.content === 'string') {
              p.content = p.content.slice(0, 500) + '... (truncated)';
            }
            if (p.results && Array.isArray(p.results)) {
              p.results = p.results.map(r => ({ ...r, content: r.content ? r.content.slice(0, 100) : '', snippet: r.snippet ? r.snippet.slice(0, 100) : '' }));
            }
            if (p.neighbors && Array.isArray(p.neighbors)) {
              p.neighbors = p.neighbors.map(n => ({ ...n, content: n.content ? n.content.slice(0, 100) : '' }));
            }
            resultToSave = JSON.stringify(p);
          } catch (e) {
            resultToSave = resultToSave.slice(0, 4000);
          }

          // Persist tool call record
          allToolCalls.push({
            name: fnName,
            args: fnArgs,
            result: resultToSave,
            intermediateText: streamContent && streamContent.trim() ? streamContent : null,
            duration,
          });
        }

        // Check if user requested stop while tools were executing
        if (streamState.isStopped) {
          console.log(`🛑 [Chat] Session ${sessionId} stopped after tool execution finished. Aborting further replies.`);
          done = true;
          break;
        }

        // reset and loop for the next response
        assistantText = '';
      } else {
        // no tool calls — streaming is complete
        let finalUsageStr = '';
        if (lastUsage) {
          const pt = lastUsage.prompt_tokens || 0;
          const ct = lastUsage.completion_tokens || 0;
          const total = pt + ct;
          const maxContext = 128000; // Assume 128k for deepseek
          const percent = ((total / maxContext) * 100).toFixed(1);
          finalUsageStr = `\n\n*(System: Context Usage ${total}/${maxContext} tokens (${percent}%))*`;
          sseEvent(res, 'token', { content: finalUsageStr });
        }
        assistantText = streamContent + finalUsageStr;
        done = true;
      }
    }

    // Parse and resolve citations from assistant text
    let resolvedCitations = [];
    try {
      const rawCitations = parseCitations(assistantText);
      if (rawCitations.length > 0) {
        resolvedCitations = await resolveCitations(rawCitations, citationSources, userId, sessionId);
        sseEvent(res, 'citations', { citations: resolvedCitations });
      }
    } catch (e) {
      console.error('Citation parsing failed:', e.message);
    }

    // save assistant message with tool call history + citations in meta
    const meta = {};
    if (allToolCalls.length > 0) meta.toolCalls = allToolCalls;
    if (resolvedCitations.length > 0) meta.citations = resolvedCitations;
    if (citationSources.length > 0) meta.citationSources = citationSources;
    const hasMeta = Object.keys(meta).length > 0;
    pushMsg(sessionId, 'assistant', assistantText, hasMeta ? meta : null, userId);
    sseEvent(res, 'done', { messageId: uuidv4(), text: assistantText });
    if (!res.writableEnded) res.end();
  } catch (e) {
    console.error('Chat error:', e);
    
    // Save any partial state so we don't end up with an orphaned user message and no response
    if (assistantText || allToolCalls.length > 0) {
      const meta = {};
      if (allToolCalls.length > 0) meta.toolCalls = allToolCalls;
      if (citationSources.length > 0) meta.citationSources = citationSources;
      meta.error = e.message;
      pushMsg(sessionId, 'assistant', assistantText || '[Error occurred during generation]', Object.keys(meta).length > 0 ? meta : null, userId);
    }
    
    sseEvent(res, 'error', { message: e.message });
    if (!res.writableEnded) res.end();
  } finally {
    activeChatStreams.delete(sessionId);
  }
});

// ── GET /api/graph/node/:nodeId ──────────────────────────────────────────────

app.get('/api/graph/node/:nodeId(*)?', async (req, res) => {
  const rawNodeId = req.params.nodeId || req.query.nodeId || req.query.id || '';
  const nodeId = decodeURIComponent(rawNodeId);
  if (!nodeId) {
    return res.status(400).json({ error: 'nodeId required' });
  }

  try {
    let nodeData = null;

    // 1. Check in-memory _sourceRegistries first (by numeric id or string nodeId/title)
    let regSource = null;
    for (const sess of _sourceRegistries.values()) {
      if (Array.isArray(sess.registry)) {
        const found = sess.registry.find(s => 
          String(s.id) === String(nodeId) || 
          s.nodeId === nodeId ||
          (s.title && s.title.toLowerCase() === nodeId.toLowerCase())
        );
        if (found) {
          regSource = found;
          break;
        }
      }
    }

    if (regSource && regSource.fullContent) {
      const nodeMeta = parseNodeMeta(regSource.fullContent);
      let links = [];
      if (regSource.rawMeta?.outboundLinks && Array.isArray(regSource.rawMeta.outboundLinks)) {
        links = regSource.rawMeta.outboundLinks;
      } else if (regSource.rawMeta?.neighbors && Array.isArray(regSource.rawMeta.neighbors)) {
        links = regSource.rawMeta.neighbors;
      }
      nodeData = {
        nodeId: regSource.nodeId || String(regSource.id),
        title: regSource.title || '',
        content: regSource.fullContent,
        sourceUrl: regSource.sourceUrl || nodeMeta.sourceUrl,
        crawledAt: regSource.crawledAt || nodeMeta.crawledAt,
        outboundLinks: links.map(l => ({
          nodeId: l.nodeId || l.id || null,
          title: l.title || l.display || 'Link',
          url: l.url || l.sourceUrl || null,
        })),
      };
    }

    // 2. Check private vaults if not found or if we need complete outbound links
    try {
      const vaultsDir = path.join(__dirname, '../networker/MCP/private_vaults');
      if (existsSync(vaultsDir)) {
        const userDirs = await fsPromises.readdir(vaultsDir);
        for (const uDir of userDirs) {
          const indexPath = path.join(vaultsDir, uDir, 'index.json');
          if (existsSync(indexPath)) {
            const privateIndex = JSON.parse(await fsPromises.readFile(indexPath, 'utf-8'));
            if (privateIndex.nodes) {
              let targetId = nodeId;
              if (!privateIndex.nodes[targetId]) {
                targetId = Object.keys(privateIndex.nodes).find(k => 
                  k === nodeId || 
                  k.toLowerCase() === nodeId.toLowerCase() ||
                  privateIndex.nodes[k].title?.toLowerCase() === nodeId.toLowerCase() ||
                  (regSource && (privateIndex.nodes[k].title?.toLowerCase() === regSource.title?.toLowerCase() || k === regSource.nodeId))
                );
              }

              if (targetId && privateIndex.nodes[targetId]) {
                const pNode = privateIndex.nodes[targetId];
                const edges = privateIndex.edges || [];
                const outbound = edges
                  .filter(e => e.source === targetId)
                  .map(e => {
                    const t = privateIndex.nodes[e.target];
                    return { nodeId: e.target, title: t?.title || 'Link', url: t?.url };
                  });
                const inbound = edges
                  .filter(e => e.target === targetId)
                  .map(e => {
                    const s = privateIndex.nodes[e.source];
                    return { nodeId: e.source, title: s?.title || 'Link', url: s?.url };
                  });

                const allLinksMap = new Map();
                for (const link of [...outbound, ...inbound]) {
                  if (link.nodeId && !allLinksMap.has(link.nodeId)) {
                    allLinksMap.set(link.nodeId, link);
                  }
                }
                const combinedLinks = Array.from(allLinksMap.values());
                const nodeMeta = parseNodeMeta(pNode.content || '');

                nodeData = {
                  nodeId: pNode.id || targetId,
                  title: pNode.title || nodeData?.title || '',
                  content: pNode.content || nodeData?.content || '',
                  sourceUrl: pNode.url || nodeMeta.sourceUrl || nodeData?.sourceUrl,
                  crawledAt: nodeMeta.crawledAt || nodeData?.crawledAt || null,
                  outboundLinks: combinedLinks.length > 0 ? combinedLinks : (nodeData?.outboundLinks || []),
                };
                break;
              }
            }
          }
        }
      }
    } catch (e) {
      console.error('Error searching private vaults:', e.message);
    }

    // 3. Check public index
    try {
      if (!nodeData || !nodeData.outboundLinks || nodeData.outboundLinks.length === 0) {
        const pubIndexPath = path.join(__dirname, '../networker/MCP/index.json');
        if (existsSync(pubIndexPath)) {
          const pubIndex = JSON.parse(await fsPromises.readFile(pubIndexPath, 'utf-8'));
          if (pubIndex.nodes) {
            let targetId = nodeId;
            if (!pubIndex.nodes[targetId]) {
              targetId = Object.keys(pubIndex.nodes).find(k => 
                k === nodeId || 
                k.toLowerCase() === nodeId.toLowerCase() ||
                pubIndex.nodes[k].title?.toLowerCase() === nodeId.toLowerCase() ||
                (regSource && (pubIndex.nodes[k].title?.toLowerCase() === regSource.title?.toLowerCase() || k === regSource.nodeId))
              );
            }

            if (targetId && pubIndex.nodes[targetId]) {
              const pNode = pubIndex.nodes[targetId];
              const edges = pubIndex.edges || [];
              const outbound = edges
                .filter(e => e.source === targetId)
                .map(e => {
                  const t = pubIndex.nodes[e.target];
                  return { nodeId: e.target, title: t?.title || 'Link', url: t?.url };
                });
              const inbound = edges
                .filter(e => e.target === targetId)
                .map(e => {
                  const s = pubIndex.nodes[e.source];
                  return { nodeId: e.source, title: s?.title || 'Link', url: s?.url };
                });

              const allLinksMap = new Map();
              for (const link of [...outbound, ...inbound]) {
                if (link.nodeId && !allLinksMap.has(link.nodeId)) {
                  allLinksMap.set(link.nodeId, link);
                }
              }
              const combinedLinks = Array.from(allLinksMap.values());
              const nodeMeta = parseNodeMeta(pNode.content || '');

              nodeData = {
                nodeId: pNode.id || targetId,
                title: pNode.title || nodeData?.title || '',
                content: pNode.content || nodeData?.content || '',
                sourceUrl: pNode.url || nodeMeta.sourceUrl || nodeData?.sourceUrl,
                crawledAt: nodeMeta.crawledAt || nodeData?.crawledAt || null,
                outboundLinks: combinedLinks.length > 0 ? combinedLinks : (nodeData?.outboundLinks || []),
              };
            }
          }
        }
      }
    } catch (e) {
      console.error('Error searching public index:', e.message);
    }

    // 4. Fallback to Networker MCP callTool('read', { nodeId })
    if (!nodeData) {
      let result = await mcpManager.callTool('read', { nodeId });
      if (!result && (nodeId.startsWith('http://') || nodeId.startsWith('https://'))) {
        const urlNode = await mcpManager.lookupNodeByUrl(nodeId);
        if (urlNode?.nodeId) {
          result = await mcpManager.callTool('read', { nodeId: urlNode.nodeId });
        }
      }

      if (result) {
        try {
          const parsed = JSON.parse(result);
          const rawContent = parsed.content || '';
          const nodeMeta = parseNodeMeta(rawContent);
          const outbound = [];
          if (parsed.neighbors && Array.isArray(parsed.neighbors)) {
            for (const n of parsed.neighbors) {
              outbound.push({
                nodeId: n.nodeId || n.id,
                title: n.title || 'Link',
                url: n.sourceUrl || n.url,
              });
            }
          }
          if (parsed.outboundLinks && Array.isArray(parsed.outboundLinks)) {
            for (const l of parsed.outboundLinks) {
              outbound.push({
                nodeId: l.nodeId || l.id,
                title: l.title || 'Link',
                url: l.url || l.sourceUrl,
              });
            }
          }
          nodeData = {
            nodeId: parsed.nodeId || nodeId,
            title: parsed.title || '',
            content: rawContent,
            sourceUrl: nodeMeta.sourceUrl,
            crawledAt: nodeMeta.crawledAt,
            outboundLinks: outbound,
          };
        } catch (_) {}
      }
    }

    if (!nodeData) {
      return res.status(404).json({ error: 'Node not found' });
    }

    res.json(nodeData);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── GET /api/memory ───────────────────────────────────────────────────────────

app.get('/api/memory', async (req, res) => {
  const { userId } = req.query;
  if (!userId) return res.status(400).json({ error: 'userId required' });
  const content = (await mcpManager.getMemory(userId)) || '';
  res.json({ content });
});

// ── PUT /api/memory ───────────────────────────────────────────────────────────

app.put('/api/memory', async (req, res) => {
  const { userId, content } = req.body;
  if (!userId || content == null) return res.status(400).json({ error: 'userId and content required' });

  // Read current, then str_replace entire content
  const old = (await mcpManager.getMemory(userId)) || '';
  if (old === content) return res.json({ ok: true });

  const result = await mcpManager.callTool('str_replace', { userId, old_str: old, new_str: content });
  if (result && !result.includes('error')) {
    return res.json({ ok: true });
  }
  // Fallback: direct file write through MCP insert trick
  // Just write the file directly as last resort
  const fs = await import('node:fs');
  const memDir = path.join(__dirname, 'memories');
  if (!fs.existsSync(memDir)) fs.mkdirSync(memDir, { recursive: true });
  const safeId = String(userId).replace(/[^a-zA-Z0-9_\-.]/g, '_');
  fs.writeFileSync(path.join(memDir, `${safeId}.md`), content, 'utf-8');
  res.json({ ok: true });
});

// ── PATCH /api/sessions/:id ──────────────────────────────────────────────────

app.patch('/api/sessions/:id', (req, res) => {
  const { id } = req.params;
  if (!sessions.has(id)) return res.status(404).json({ error: 'session not found' });
  const session = sessions.get(id);
  if (req.body.title !== undefined) session.title = req.body.title;
  if (req.body.pinned !== undefined) session.pinned = !!req.body.pinned;
  session.lastActive = new Date().toISOString();
  sessions.set(id, session);
  saveData();
  res.json(session);
});

// ── POST /api/messages/rollback ──────────────────────────────────────────────

app.post('/api/messages/rollback', (req, res) => {
  const { sessionId, messageId } = req.body;
  if (!sessionId || !messageId) {
    return res.status(400).json({ error: 'sessionId and messageId required' });
  }

  const arr = messages.get(sessionId);
  if (!arr) return res.status(404).json({ error: 'session not found' });

  const idx = arr.findIndex(m => m.id === messageId);
  if (idx === -1) return res.status(404).json({ error: 'message not found' });

  // truncate
  messages.set(sessionId, arr.slice(0, idx));
  saveData();

  res.json({ success: true });
});

// ── Google Calendar OAuth & API ──────────────────────────────────────────────

app.get('/oauth/google/connect', (req, res) => {
  const { userId } = req.query;
  if (!userId) return res.status(400).send('userId is required');

  const oauth2Client = new google.auth.OAuth2(
    process.env.GOOGLE_CLIENT_ID,
    process.env.GOOGLE_CLIENT_SECRET,
    process.env.GOOGLE_REDIRECT_URI
  );

  const url = oauth2Client.generateAuthUrl({
    access_type: 'offline',
    prompt: 'consent',
    scope: [
      'https://www.googleapis.com/auth/calendar.events', 
      'https://www.googleapis.com/auth/calendar.readonly',
      'https://www.googleapis.com/auth/gmail.readonly'
    ],
    state: userId
  });
  
  res.redirect(url);
});

app.get('/oauth/google/callback', async (req, res) => {
  const code = req.query.code;
  const userId = req.query.state;

  if (!code || !userId) return res.status(400).send('Invalid callback parameters');

  try {
    const oauth2Client = new google.auth.OAuth2(
      process.env.GOOGLE_CLIENT_ID,
      process.env.GOOGLE_CLIENT_SECRET,
      process.env.GOOGLE_REDIRECT_URI
    );

    const { tokens } = await oauth2Client.getToken(code);
    
    let user = users.get(userId);
    if (!user) user = Object.values(Object.fromEntries(users)).find(u => u.userId === userId);
    if (!user) {
       user = { userId, username: userId };
       users.set(userId, user);
    }
    
    // Only overwrite refresh token if it's provided (sometimes Google omits it if already consented and no prompt=consent)
    if (tokens.refresh_token) {
        user.google_refresh_token = tokens.refresh_token;
    }
    if (tokens.access_token) user.google_access_token = tokens.access_token;
    saveData();
    
    res.send(`
      <html>
        <body>
          <h2>Google Calendar Connected!</h2>
          <p>You can close this window/tab and return to the CollegeAgent app.</p>
        </body>
      </html>
    `);
  } catch (error) {
    console.error('Failed to get token:', error);
    res.status(500).send('Failed to connect Google Calendar.');
  }
});

app.get('/api/calendar/events', async (req, res) => {
  const { userId } = req.query;
  if (!userId) return res.status(400).json({ error: 'userId is required' });

  let user = users.get(userId);
  if (!user) user = Object.values(Object.fromEntries(users)).find(u => u.userId === userId);

  if (!user || !user.google_refresh_token) {
    return res.status(401).json({ error: 'Not connected to Google Calendar', needsAuth: true });
  }

  const oauth2Client = new google.auth.OAuth2(
    process.env.GOOGLE_CLIENT_ID,
    process.env.GOOGLE_CLIENT_SECRET
  );
  oauth2Client.setCredentials({ refresh_token: user.google_refresh_token });

  const calendar = google.calendar({ version: 'v3', auth: oauth2Client });
  try {
    const response = await calendar.events.list({
      calendarId: 'primary',
      timeMin: (new Date()).toISOString(),
      maxResults: 100,
      singleEvents: true,
      orderBy: 'startTime',
    });
    res.json(response.data.items || []);
  } catch (error) {
    console.error('Calendar API error:', error.message);
    if (error.message.includes('invalid_grant') || error.message.includes('insufficient authentication scopes')) {
      return res.status(401).json({ error: 'Token expired or revoked', needsAuth: true });
    }
    res.status(500).json({ error: error.message });
  }
});

// ── GMAIL APIs ─────────────────────────────────────────────────────────────

app.get('/api/gmail/messages', async (req, res) => {
  const { userId } = req.query;
  if (!userId) return res.status(400).json({ error: 'userId is required' });

  let user = users.get(userId);
  if (!user) user = Object.values(Object.fromEntries(users)).find(u => u.userId === userId);

  if (!user || !user.google_refresh_token) {
    return res.status(401).json({ error: 'Not connected to Google Account', needsAuth: true });
  }

  // Check vault for inVault status
  const privateIndexPath = path.join('/home/collegeagent/networker/MCP/private_vaults', userId, 'index.json');
  let privateIndex = { nodes: {} };
  if (existsSync(privateIndexPath)) {
    try { privateIndex = JSON.parse(readFileSync(privateIndexPath, 'utf-8')); } catch (e) {}
  }
  const nodes = privateIndex.nodes || {};

  const oauth2Client = new google.auth.OAuth2(
    process.env.GOOGLE_CLIENT_ID,
    process.env.GOOGLE_CLIENT_SECRET
  );
  oauth2Client.setCredentials({ refresh_token: user.google_refresh_token });

  const gmail = google.gmail({ version: 'v1', auth: oauth2Client });
  try {
    const response = await gmail.users.messages.list({
      userId: 'me',
      maxResults: 20,
    });
    const messages = response.data.messages || [];
    const emailDetails = [];
    
    for (const msg of messages) {
      const nodeId = `gmail_${msg.id}`;
      const cachedNode = nodes[nodeId];
      if (cachedNode) {
        emailDetails.push({
          id: msg.id,
          snippet: cachedNode.content?.slice(0, 150) || '',
          subject: cachedNode.title || '(No Subject)',
          from: cachedNode.from || 'Unknown',
          date: cachedNode.date || '',
          inVault: true,
        });
      } else {
        const msgData = await gmail.users.messages.get({
          userId: 'me',
          id: msg.id,
          format: 'metadata',
          metadataHeaders: ['Subject', 'From', 'Date']
        });
        const headers = msgData.data.payload?.headers || [];
        emailDetails.push({
          id: msg.id,
          snippet: msgData.data.snippet || '',
          subject: headers.find(h => h.name === 'Subject')?.value || '(No Subject)',
          from: headers.find(h => h.name === 'From')?.value || 'Unknown',
          date: headers.find(h => h.name === 'Date')?.value || '',
          inVault: false,
        });
      }
    }
    res.json(emailDetails);
  } catch (error) {
    console.error('Gmail API error:', error.message);
    if (error.message.includes('invalid_grant') || error.message.includes('insufficient authentication scopes')) {
      return res.status(401).json({ error: 'Token expired or revoked', needsAuth: true });
    }
    res.status(500).json({ error: error.message });
  }
});

app.get('/api/gmail/message/:id', async (req, res) => {
  const { id } = req.params;
  const { userId } = req.query;
  if (!userId) return res.status(400).json({ error: 'userId is required' });

  // 1. Check if in vault
  const privateIndexPath = path.join('/home/collegeagent/networker/MCP/private_vaults', userId, 'index.json');
  let privateIndex = { nodes: {}, edges: [] };
  if (existsSync(privateIndexPath)) {
    try { privateIndex = JSON.parse(readFileSync(privateIndexPath, 'utf-8')); } catch (e) {}
  }
  const nodeId = `gmail_${id}`;
  const vaultNode = privateIndex.nodes?.[nodeId];
  if (vaultNode && vaultNode.content) {
    const outboundEdges = (privateIndex.edges || []).filter(e => e.source === nodeId);
    const outboundLinks = outboundEdges.map(e => {
      const target = privateIndex.nodes?.[e.target];
      return {
        nodeId: e.target,
        title: target?.title || 'Link',
        url: target?.url || target?.sourceUrl || '',
        summary: target?.summary || ''
      };
    });

    return res.json({
      id,
      subject: vaultNode.title,
      from: vaultNode.from || 'Unknown',
      date: vaultNode.date || '',
      inVault: true,
      content: vaultNode.content,
      html: vaultNode.html || '',
      outboundLinks: outboundLinks.length > 0 ? outboundLinks : (vaultNode.outboundLinks || [])
    });
  }

  // 2. Fallback: fetch from Gmail API if not in vault
  let user = users.get(userId);
  if (!user) user = Object.values(Object.fromEntries(users)).find(u => u.userId === userId);

  if (!user || !user.google_refresh_token) {
    return res.status(401).json({ error: 'Not connected to Google Account', needsAuth: true });
  }

  const oauth2Client = new google.auth.OAuth2(
    process.env.GOOGLE_CLIENT_ID,
    process.env.GOOGLE_CLIENT_SECRET
  );
  oauth2Client.setCredentials({ refresh_token: user.google_refresh_token });

  const gmail = google.gmail({ version: 'v1', auth: oauth2Client });
  try {
    const msgData = await gmail.users.messages.get({
      userId: 'me',
      id: id,
      format: 'full',
    });
    
    let htmlBody = '';
    let textBody = '';
    
    function getBody(payload) {
      if (!payload) return;
      if (payload.mimeType === 'text/html' && payload.body && payload.body.data) {
        htmlBody = Buffer.from(payload.body.data, 'base64url').toString('utf8');
      } else if (payload.mimeType === 'text/plain' && payload.body && payload.body.data) {
        textBody = Buffer.from(payload.body.data, 'base64url').toString('utf8');
      }
      
      if (payload.parts) {
        payload.parts.forEach(getBody);
      }
    }
    
    getBody(msgData.data.payload);
    
    const headers = msgData.data.payload?.headers || [];
    res.json({
      id: msgData.data.id,
      subject: headers.find(h => h.name === 'Subject')?.value || '(No Subject)',
      from: headers.find(h => h.name === 'From')?.value || 'Unknown',
      date: headers.find(h => h.name === 'Date')?.value || '',
      inVault: false,
      html: htmlBody || textBody || '<p>No content available.</p>',
      outboundLinks: []
    });
  } catch (error) {
    console.error('Gmail API detail error:', error.message);
    res.status(500).json({ error: error.message });
  }
});

// ─── GMAIL VAULT SYNC ENGINE ────────────────────────────────────────────────
const gmailSyncStatus = new Map(); // userId -> { status: 'idle'|'syncing', lastSync: number, error?: string, count?: number }

async function syncGmailVault(userId) {
  if (!userId) return;
  const currentStatus = gmailSyncStatus.get(userId);
  if (currentStatus?.status === 'syncing') {
    return { syncing: true, message: 'Sync already in progress' };
  }

  let user = users.get(userId);
  if (!user) user = Object.values(Object.fromEntries(users)).find(u => u.userId === userId);
  if (!user || !user.google_refresh_token) {
    return { error: 'Not connected to Google Account', needsAuth: true };
  }

  gmailSyncStatus.set(userId, { status: 'syncing', startTime: Date.now() });

  try {
    const oauth2Client = new google.auth.OAuth2(
      process.env.GOOGLE_CLIENT_ID,
      process.env.GOOGLE_CLIENT_SECRET
    );
    oauth2Client.setCredentials({ refresh_token: user.google_refresh_token });
    const gmail = google.gmail({ version: 'v1', auth: oauth2Client });

    const listRes = await gmail.users.messages.list({
      userId: 'me',
      maxResults: 25,
    });
    const messageList = listRes.data.messages || [];

    const privateVaultDir = path.join('/home/collegeagent/networker/MCP/private_vaults', userId);
    const privateIndexPath = path.join(privateVaultDir, 'index.json');
    if (!existsSync(privateVaultDir)) {
      mkdirSync(privateVaultDir, { recursive: true });
    }

    let privateIndex = { nodes: {}, edges: [] };
    if (existsSync(privateIndexPath)) {
      try {
        privateIndex = JSON.parse(readFileSync(privateIndexPath, 'utf-8'));
      } catch (e) {
        privateIndex = { nodes: {}, edges: [] };
      }
    }
    if (!privateIndex.nodes) privateIndex.nodes = {};
    if (!privateIndex.edges) privateIndex.edges = [];

    const turndownService = new TurndownService({
      headingStyle: 'atx',
      codeBlockStyle: 'fenced'
    });
    turndownService.remove(['style', 'script', 'head', 'noscript', 'meta']);

    const outboundUrlsToCrawl = new Set();
    let newNodesCount = 0;

    for (const item of messageList) {
      const msgId = item.id;
      const nodeId = `gmail_${msgId}`;

      // If already in index and has content, skip refetching
      if (privateIndex.nodes[nodeId] && privateIndex.nodes[nodeId].content) {
        continue;
      }

      try {
        const msgData = await gmail.users.messages.get({
          userId: 'me',
          id: msgId,
          format: 'full',
        });

        let htmlBody = '';
        let textBody = '';
        function getBody(payload) {
          if (!payload) return;
          if (payload.mimeType === 'text/html' && payload.body && payload.body.data) {
            htmlBody = Buffer.from(payload.body.data, 'base64url').toString('utf8');
          } else if (payload.mimeType === 'text/plain' && payload.body && payload.body.data) {
            textBody = Buffer.from(payload.body.data, 'base64url').toString('utf8');
          }
          if (payload.parts) {
            payload.parts.forEach(getBody);
          }
        }
        getBody(msgData.data.payload);

        const headers = msgData.data.payload?.headers || [];
        const subject = headers.find(h => h.name === 'Subject')?.value || '(No Subject)';
        const from = headers.find(h => h.name === 'From')?.value || 'Unknown';
        const date = headers.find(h => h.name === 'Date')?.value || '';
        
        let markdownBody = '';
        if (htmlBody) {
          markdownBody = turndownService.turndown(htmlBody);
        } else {
          markdownBody = textBody;
        }

        // Extract outbound URLs
        const linkRegex = /\[(.*?)\]\((https?:\/\/[^\)\s]+)(?:\s+"[^"]*")?\)/g;
        let match;
        const outboundLinks = [];
        while ((match = linkRegex.exec(markdownBody)) !== null) {
          const title = match[1] || 'Link';
          const url = match[2];
          if (url && !url.includes('google.com/mail') && !url.includes('mail.google.com')) {
            const urlHash = createHash('md5').update(url).digest('hex').substring(0, 16);
            const targetNodeId = `url_${urlHash}`;
            outboundLinks.push({ nodeId: targetNodeId, url, title });
            outboundUrlsToCrawl.add(url);

            if (!privateIndex.nodes[targetNodeId]) {
              privateIndex.nodes[targetNodeId] = {
                id: targetNodeId,
                title: title || 'External Link',
                url: url,
                content: '',
                source: 'Gmail',
                source_type: 'Gmail'
              };
            }
            const edgeExists = privateIndex.edges.some(e => e.source === nodeId && e.target === targetNodeId);
            if (!edgeExists) {
              privateIndex.edges.push({ source: nodeId, target: targetNodeId });
            }
          }
        }

        const safeFilename = `gmail_${msgId}.md`;
        const emailUrl = `https://mail.google.com/mail/u/0/#inbox/${msgId}`;
        const nodeContent = `# ${subject}\n\n- **From**: ${from}\n- **Date**: ${date}\n- **Source**: Gmail\n- **Source URL**: [${emailUrl}](${emailUrl})\n- **User ID**: ${userId}\n\n## Content\n\n${markdownBody}`;

        privateIndex.nodes[nodeId] = {
          id: nodeId,
          title: subject,
          source: 'Gmail',
          source_type: 'Gmail',
          url: emailUrl,
          from: from,
          date: date,
          path: safeFilename,
          content: nodeContent,
          html: htmlBody || textBody,
          outboundLinks: outboundLinks
        };

        const mdPath = path.join(privateVaultDir, safeFilename);
        writeFileSync(mdPath, nodeContent, 'utf-8');

        newNodesCount++;
      } catch (msgErr) {
        console.error(`Error processing message ${msgId}:`, msgErr.message);
      }
    }

    // Save index.json
    writeFileSync(privateIndexPath, JSON.stringify(privateIndex, null, 2), 'utf-8');

    // Trigger Networker 1-hop crawl for outbound URLs
    const filteredUrls = Array.from(outboundUrlsToCrawl).filter(url => {
      try {
        const u = new URL(url);
        if (u.pathname.match(/\.(png|jpg|jpeg|gif|pdf|docx|zip)$/i)) return false;
        return true;
      } catch (e) { return false; }
    });

    if (filteredUrls.length > 0) {
      try {
        await fetch('http://127.0.0.1:4090/api/tasks/batch', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            urls: filteredUrls.slice(0, 30),
            vaultPath: privateVaultDir,
            userId: userId
          })
        });
      } catch (crawlErr) {
        console.error('Failed to trigger 1-hop crawl on Networker for Gmail:', crawlErr.message);
      }
    }

    // Trigger AutoRAG reindex
    try {
      await fetch('http://127.0.0.1:8002/reindex', { method: 'POST' });
    } catch (reindexErr) {
      console.error('Failed to trigger AutoRAG reindex for Gmail:', reindexErr.message);
    }

    gmailSyncStatus.set(userId, { status: 'idle', lastSync: Date.now(), count: newNodesCount });
    return { success: true, count: newNodesCount };
  } catch (error) {
    console.error('Gmail sync error:', error.message);
    gmailSyncStatus.set(userId, { status: 'idle', lastSync: Date.now(), error: error.message });
    return { error: error.message };
  }
}

app.post('/api/gmail/sync', async (req, res) => {
  const userId = req.body?.userId || req.query?.userId;
  if (!userId) return res.status(400).json({ error: 'userId is required' });
  const status = gmailSyncStatus.get(userId);
  if (status?.status === 'syncing') {
    return res.json({ syncing: true, message: 'Sync already in progress' });
  }
  syncGmailVault(userId).catch(console.error);
  res.json({ success: true, message: 'Gmail sync started' });
});

app.get('/api/gmail/sync-status', (req, res) => {
  const { userId } = req.query;
  if (!userId) return res.status(400).json({ error: 'userId is required' });
  const status = gmailSyncStatus.get(userId) || { status: 'idle', lastSync: 0 };
  res.json({
    syncing: status.status === 'syncing',
    lastSync: status.lastSync || 0,
    error: status.error || null,
    count: status.count || 0
  });
});

// Hourly background auto-sync for active users with tokens
setInterval(() => {
  console.log('⏰ Running hourly Gmail auto-sync...');
  for (const user of users.values()) {
    if (user.google_refresh_token) {
      syncGmailVault(user.userId).catch(e => console.error(`Hourly sync error for user ${user.userId}:`, e.message));
    }
  }
}, 60 * 60 * 1000);


// ── CANVAS PROXY APIs ──────────────────────────────────────────────────────

app.get('/api/canvas/courses', async (req, res) => {
  try {
    const fetch = (await import('node-fetch')).default || globalThis.fetch;
    const r = await fetch('http://127.0.0.1:4091/api/courses');
    const data = await r.json();
    if (data.error || data.errors) { res.status(500).json(data); } else { res.json(data); }
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/canvas/modules', async (req, res) => {
  try {
    const { courseId } = req.query;
    const fetch = (await import('node-fetch')).default || globalThis.fetch;
    const r = await fetch(`http://127.0.0.1:4091/api/courses/${courseId}/modules`);
    const data = await r.json();
    if (data.error || data.errors) { res.status(500).json(data); } else { res.json(data); }
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/canvas/assignments', async (req, res) => {
  try {
    const { courseId } = req.query;
    const fetch = (await import('node-fetch')).default || globalThis.fetch;
    const r = await fetch(`http://127.0.0.1:4091/api/courses/${courseId}/assignments`);
    const data = await r.json();
    if (data.error || data.errors) { res.status(500).json(data); } else { res.json(data); }
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/canvas/pages', async (req, res) => {
  // Canvas /api/courses/:courseId/files or pages?
  // Let's just return files or something similar if pages isn't strictly defined, or empty array.
  try {
    const { courseId } = req.query;
    const fetch = (await import('node-fetch')).default || globalThis.fetch;
    const r = await fetch(`http://127.0.0.1:4091/api/courses/${courseId}/files`);
    const data = await r.json();
    if (data.error || data.errors) { res.status(500).json(data); } else { res.json(data); }
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});


// ── CANVAS VAULT STATUS & BATCH FETCH APIs ───────────────────────────────────

app.get('/api/canvas/vault-status', async (req, res) => {
  const { userId } = req.query;
  if (!userId) return res.status(400).json({ error: 'userId is required' });

  try {
    const vaultPath = path.join(__dirname, '../networker/MCP/private_vaults', userId, 'index.json');
    if (!existsSync(vaultPath)) {
      return res.json({ savedKeys: [] });
    }
    const indexData = JSON.parse(await fsPromises.readFile(vaultPath, 'utf-8'));
    const savedKeys = new Set();
    
    if (indexData.nodes) {
      Object.keys(indexData.nodes).forEach(k => {
        savedKeys.add(k);
        const node = indexData.nodes[k];
        if (node.title) savedKeys.add(node.title);
        if (node.path) savedKeys.add(node.path);
        if (node.page_url) savedKeys.add(node.page_url);
        if (node.url) savedKeys.add(node.url);
      });
    }
    res.json({ savedKeys: Array.from(savedKeys) });
  } catch (e) {
    console.error('Error in vault-status:', e);
    res.status(500).json({ error: e.message });
  }
});

app.post('/api/canvas/batch-fetch-graph', async (req, res) => {
  const { userId, pages } = req.body;
  if (!userId || !Array.isArray(pages)) {
    return res.status(400).json({ error: 'userId and pages array required' });
  }

  // AGENTS.md Post-Mortem 5.A: Sequential processing to prevent vault index.json overwrite
  (async () => {
    for (const p of pages) {
      try {
        await mcpManager.callTool('get_page_content', {
          courseId: p.courseId ? String(p.courseId) : undefined,
          moduleId: p.moduleId ? String(p.moduleId) : undefined,
          pageId: p.pageId ? String(p.pageId) : (p.page_url || p.urlOrId),
          urlOrId: p.urlOrId || p.page_url || p.pageId,
          itemId: p.itemId ? String(p.itemId) : undefined,
          itemType: p.itemType || 'Page',
          userId: userId
        });
      } catch (err) {
        console.error('Batch fetch error for page:', p, err.message);
      }
    }
  })().catch(e => console.error('Batch fetch loop error:', e));

  res.json({ success: true, queuedCount: pages.length });
});

// ── DELETE /api/sessions/:id ─────────────────────────────────────────────────

app.delete('/api/sessions/:id', (req, res) => {
  const { id } = req.params;
  if (!sessions.has(id)) return res.status(404).json({ error: 'session not found' });
  // Also delete child subagents if any
  for (const [sid, sess] of sessions.entries()) {
    if (sess.parentId === id) {
      sessions.delete(sid);
      messages.delete(sid);
      _sourceRegistries.delete(sid);
    }
  }
  sessions.delete(id);
  messages.delete(id);
  _sourceRegistries.delete(id);
  saveData();
  res.json({ ok: true });
});

// ── start ─────────────────────────────────────────────────────────────────────

async function main() {
  loadData();
  await mcpManager.start();
  app.listen(PORT, '0.0.0.0', () => {
    console.log(`🚀 CollegeAgent backend listening on 0.0.0.0:${PORT}`);
  });
}

main().catch((e) => {
  console.error('Fatal:', e);
  process.exit(1);
});
