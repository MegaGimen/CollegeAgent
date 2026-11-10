/**
 * MCP Manager — unified multi-server MCP client
 *
 * Manages connections to multiple MCP servers (memory, canvas, networker).
 * Provides:
 *   - getAllTools()     → flat array of DeepSeek-compatible tool definitions
 *   - callTool(name, args) → route call to the correct MCP server
 *   - getMemory(userId) → convenience for reading user memory (used by system prompt injection)
 */

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const NODE_BIN = '/root/.nvm/versions/node/v24.12.0/bin/node';

// Tools to exclude from DeepSeek tool list
const EXCLUDED_TOOLS = new Set(['list_tools']);

class McpManager {
  /** @type {Object<string, { client: Client, tools: Array, transport: StdioClientTransport }>} */
  servers = {};

  /**
   * Start all MCP servers defined in config + the built-in memory MCP.
   */
  async start() {
    // 1. Memory MCP (built-in)
    await this._connectServer('memory', NODE_BIN, [
      path.join(__dirname, 'memory_mcp.js'),
    ]);

    // 1.5 Calendar MCP (built-in)
    await this._connectServer('calendar', NODE_BIN, [
      path.join(__dirname, 'calendar_mcp.js'),
    ]);

    // 2. External MCPs from /home/collegeagent/mcp.json
    try {
      const mcpConfig = JSON.parse(
        readFileSync('/home/collegeagent/mcp.json', 'utf-8'),
      );
      for (const [name, cfg] of Object.entries(mcpConfig.mcpServers || {})) {
        await this._connectServer(name, cfg.command, cfg.args || []);
      }
    } catch (e) {
      console.error('⚠️  Failed to load mcp.json:', e.message);
    }

    const totalTools = this.getAllTools().length;
    const serverNames = Object.keys(this.servers);
    console.log(
      `🔧 MCP Manager ready: ${serverNames.length} servers (${serverNames.join(', ')}), ${totalTools} tools`,
    );
  }

  /**
   * Connect to a single MCP server via stdio.
   */
  async _connectServer(name, command, args) {
    try {
      const transport = new StdioClientTransport({ command, args, stderr: 'pipe' });
      const client = new Client({ name: `collegeagent-${name}`, version: '1.0.0' });

      await client.connect(transport);

      // Pipe stderr for debugging
      if (transport.stderr) {
        transport.stderr.on('data', (d) =>
          process.stderr.write(`[${name}] ${d}`),
        );
      }

      // Fetch tool list from server
      const { tools } = await client.listTools();

      this.servers[name] = { client, tools, transport };
      console.log(
        `  ✅ ${name}: ${tools.length} tools (${tools.map((t) => t.name).join(', ')})`,
      );
    } catch (e) {
      console.error(`  ❌ ${name}: failed to connect — ${e.message}`);
    }
  }

  /**
   * Get all tools from all servers, converted to DeepSeek function-calling format.
   * Excludes tools in EXCLUDED_TOOLS set.
   * Remaps `nodeId` params to `sourceId` for read/expand so the agent only sees integer IDs.
   */
  getAllTools() {
    const tools = [];
    for (const { tools: serverTools } of Object.values(this.servers)) {
      for (const t of serverTools) {
        if (EXCLUDED_TOOLS.has(t.name)) continue;

        let params = t.inputSchema || { type: 'object', properties: {} };

        // Remap nodeId → sourceId for read and expand tools
        if (t.name === 'read' || t.name === 'expand') {
          params = JSON.parse(JSON.stringify(params)); // deep clone
          if (params.properties?.nodeId) {
            params.properties.sourceId = {
              type: 'number',
              description: 'The source ID (small integer from search, expand, or get_files results) of the item to read or expand',
            };
            delete params.properties.nodeId;
          }
          if (t.name === 'read') {
            if (!params.properties) params.properties = {};
            params.properties.courseId = {
              type: 'string',
              description: 'Optional course ID if reading a Canvas course file directly',
            };
            params.properties.fileId = {
              type: 'string',
              description: 'Optional Canvas file ID if reading a Canvas course file directly',
            };
            params.required = [];
          } else if (Array.isArray(params.required)) {
            params.required = params.required.map(r => r === 'nodeId' ? 'sourceId' : r);
          }
          // expand accepts either sourceId or url — clear required so neither is mandatory
          if (t.name === 'expand') {
            params.required = [];
          }
        }

        // Update descriptions to reference sourceId
        let desc = t.description || '';
        if (t.name === 'search') {
          desc = 'Search the knowledge graph across multiple vaults (public, course, Gmail, personal). Returns ONLY short preview snippets and sourceIds. Does NOT return full document content or line numbers. You MUST call read(sourceId) on relevant result(s) to fetch the full document before answering or citing.';
        } else if (t.name === 'read') {
          desc = 'Read the full content of a source by its sourceId (from search results, or files listed via get_files). Returns full document with line numbers ( 1|..., 2|...) and outbound links. Supports reading vault notes, web pages, emails, and course files (PDF, PPTX, DOCX, XLSX, etc.). Always call this to read documents found via search or get_files.';
        } else if (t.name === 'expand') {
          desc = 'Two modes: (1) expand(url) — crawl a URL from web_search results, save to vault, return full line-numbered content with outbound links and a sourceId. Use this after web_search to read specific pages. (2) expand(sourceId) — read all 1-hop neighbors of an existing graph node. Provide exactly one of: url or sourceId.';
        } else if (t.name === 'get_files') {
          desc = 'Get a catalog list of files for a course (IDs, names, sizes). Files listed here receive numeric sourceIds and can be read in full (PDF, PPTX, DOCX, XLSX, etc.) with line numbers by calling read(sourceId).';
        }

        tools.push({
          type: 'function',
          function: {
            name: t.name,
            description: desc,
            parameters: params,
          },
        });
      }
    }
    return tools;
  }

  /**
   * Call a tool by name. Routes to the correct MCP server.
   * Returns the text result or null on failure.
   */
  async callTool(name, args) {
    const normalizedName = typeof name === 'string' ? name.replace(/-/g, '_') : name;
    for (const { client } of Object.values(this.servers)) {
      try {
        // Check if this server has the tool
        const { tools } = await client.listTools();
        const hasTool = tools.some((t) => t.name === normalizedName || t.name === name);
        if (!hasTool) continue;

        const res = await client.callTool({ name: normalizedName, arguments: args });
        return res?.content?.[0]?.text ?? null;
      } catch {
        // This server doesn't have the tool or call failed, try next
      }
    }
    console.error(`⚠️  Tool not found: ${name} (normalized: ${normalizedName})`);
    return null;
  }

  /**
   * Convenience: read user memory (bypasses tool exclusion).
   */
  async getMemory(userId) {
    const memServer = this.servers['memory'];
    if (!memServer) return '';
    try {
      const res = await memServer.client.callTool({
        name: 'read_memory',
        arguments: { userId },
      });
      return res?.content?.[0]?.text ?? '';
    } catch {
      return '';
    }
  }

  /**
   * Look up a node by its source URL.
   * Uses search to find a node whose sourceUrl matches the given URL.
   * Returns { nodeId, title, sourceUrl, crawledAt, outboundLinks } or null.
   */
  async lookupNodeByUrl(url) {
    try {
      const result = await this.callTool('search', { query: url, limit: 5 });
      if (!result) return null;
      const parsed = JSON.parse(result);
      if (parsed.results && Array.isArray(parsed.results)) {
        for (const r of parsed.results) {
          if (r.sourceUrl === url || r.source_url === url) {
            return {
              nodeId: r.nodeId || null,
              title: r.title || '',
              sourceUrl: r.sourceUrl || r.source_url || null,
              crawledAt: r.crawledAt || null,
              outboundLinks: r.outboundLinks || [],
            };
          }
        }
      }
      return null;
    } catch {
      return null;
    }
  }

  /**
   * Look up a node in the knowledge graph by its title.
   * Uses search to find the node, then read to get full numbered content.
   * Returns { nodeId, title, snippet, fullContent } or null if not found.
   */
  async lookupNodeByTitle(title) {
    try {
      const result = await this.callTool('search', { query: title, limit: 3 });
      if (!result) return null;
      const parsed = JSON.parse(result);
      if (parsed.results && Array.isArray(parsed.results)) {
        // Find exact or closest title match
        const match = parsed.results.find(
          (r) => r.title && r.title.toLowerCase() === title.toLowerCase()
        ) || parsed.results[0];
        if (!match) return null;

        // Use read to get full numbered content
        let numberedContent = '';
        if (match.nodeId) {
          try {
            const readResult = await this.callTool('read', { nodeId: match.nodeId });
            if (readResult) {
              const readParsed = JSON.parse(readResult);
              numberedContent = readParsed.content || '';
            }
          } catch { /* fallback to search content */ }
        }

        // Fallback: use search content (without line numbers)
        if (!numberedContent) {
          let content = match.content || '';
          const contentIdx = content.indexOf('## Content');
          if (contentIdx !== -1) {
            content = content.slice(contentIdx + '## Content'.length).trim();
          }
          numberedContent = content;
        }

        return {
          nodeId: match.nodeId || null,
          title: match.title,
          snippet: numberedContent.replace(/^\s*\d+\|/gm, '').slice(0, 500),
          fullContent: numberedContent,
        };
      }
      return null;
    } catch {
      return null;
    }
  }

  /**
   * Stop all MCP servers.
   */
  async stop() {
    for (const [name, { transport }] of Object.entries(this.servers)) {
      try {
        await transport.close();
      } catch {
        // ignore
      }
    }
    this.servers = {};
  }
}

export default McpManager;
