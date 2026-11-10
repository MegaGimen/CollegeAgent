#!/usr/bin/env node
/**
 * Memory MCP Server — per-user persistent memory via stdio transport.
 *
 * Tools:
 *   read_memory(userId)                   – read the user's memory file
 *   str_replace(userId, old_str, new_str) – exact string replacement
 *   insert(userId, line, text)            – insert text after line number
 *
 * Storage: ./memories/<userId>.md
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { addSnapshot } from './memory_versions.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const MEMORIES_DIR = path.join(__dirname, 'memories');

// ─── helpers ──────────────────────────────────────────────────────────────────

function ensureDir() {
  if (!fs.existsSync(MEMORIES_DIR)) fs.mkdirSync(MEMORIES_DIR, { recursive: true });
}

function safeId(userId) {
  return String(userId).replace(/[^a-zA-Z0-9_\-.]/g, '_');
}

function memPath(userId) {
  return path.join(MEMORIES_DIR, `${safeId(userId)}.md`);
}

function readMem(userId) {
  ensureDir();
  const fp = memPath(userId);
  if (!fs.existsSync(fp)) {
    fs.writeFileSync(fp, `# User Memory — ${userId}\n\n`, 'utf-8');
  }
  return fs.readFileSync(fp, 'utf-8');
}

function writeMem(userId, content) {
  ensureDir();
  fs.writeFileSync(memPath(userId), content, 'utf-8');
}

// ─── tool schemas ─────────────────────────────────────────────────────────────

const TOOLS = [
  {
    name: 'read_memory',
    description: 'Read the user\'s stored memory/profile markdown file (identity, preferences, schedules, etc). Use this when you need to inspect or verify current memory content.',
    inputSchema: {
      type: 'object',
      properties: {
        userId: { type: 'string', description: 'Unique user identifier (automatically injected by system).' },
      },
    },
  },
  {
    name: 'str_replace',
    description:
      'Update a user identity/preference fact. old_str must match exactly. NOT for storing conversation history.',
    inputSchema: {
      type: 'object',
      properties: {
        userId: { type: 'string', description: 'Unique user identifier.' },
        old_str: { type: 'string', description: 'Exact existing text to find.' },
        new_str: { type: 'string', description: 'Replacement text.' },
      },
      required: ['userId', 'old_str', 'new_str'],
    },
  },
  {
    name: 'insert',
    description:
      'Add a new user identity/preference fact. NOT for storing conversation history.',
    inputSchema: {
      type: 'object',
      properties: {
        userId: { type: 'string', description: 'Unique user identifier.' },
        line: { type: 'integer', description: 'Line number after which to insert (0 = top).' },
        text: { type: 'string', description: 'Text to insert.' },
      },
      required: ['userId', 'line', 'text'],
    },
  },
];

// ─── MCP server ───────────────────────────────────────────────────────────────

const server = new Server(
  { name: 'memory-mcp', version: '1.0.0' },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const ok = (text) => ({ content: [{ type: 'text', text }] });
  const err = (msg) => ({
    content: [{ type: 'text', text: JSON.stringify({ error: msg }) }],
    isError: true,
  });

  try {
    switch (name) {
      case 'read_memory': {
        if (!args?.userId) return err('userId is required');
        return ok(readMem(args.userId));
      }

      case 'str_replace': {
        if (!args?.userId) return err('userId is required');
        const content = readMem(args.userId);
        if (!content.includes(args.old_str)) {
          return err(`old_str not found. First 500 chars:\n${content.slice(0, 500)}`);
        }
        // 1. Snapshot before agent edit
        addSnapshot(args.userId, content, 'agent_pre', 'Agent Edit (Before str_replace)');

        const newContent = content.replace(args.old_str, args.new_str);
        writeMem(args.userId, newContent);

        // 2. Snapshot after agent edit
        addSnapshot(args.userId, newContent, 'agent_post', 'Agent Edit (After str_replace)');
        return ok('Memory updated (str_replace).');
      }

      case 'insert': {
        if (!args?.userId) return err('userId is required');
        const content = readMem(args.userId);
        const lines = content.split('\n');
        const idx = Math.min(Math.max(0, args.line), lines.length);

        // 1. Snapshot before agent edit
        addSnapshot(args.userId, content, 'agent_pre', `Agent Edit (Before insert line ${args.line})`);

        lines.splice(idx, 0, args.text);
        const newContent = lines.join('\n');
        writeMem(args.userId, newContent);

        // 2. Snapshot after agent edit
        addSnapshot(args.userId, newContent, 'agent_post', `Agent Edit (After insert line ${args.line})`);
        return ok(`Memory updated (insert after line ${args.line}).`);
      }

      default:
        return err(`Unknown tool: ${name}`);
    }
  } catch (e) {
    return err(e.message);
  }
});

// ─── start ────────────────────────────────────────────────────────────────────

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(`🧠 Memory MCP started  |  dir: ${MEMORIES_DIR}`);
}

main().catch((e) => {
  console.error('❌ Memory MCP failed:', e);
  process.exit(1);
});
