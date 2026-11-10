#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';

const server = new Server(
  { name: 'collegeagent-luma', version: '1.0.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: 'get_luma_events',
        description: `Query upcoming Luma events across specified locations and categories within an optional date range.
Supports TWO distinct retrieval modes:
1. Semantic Search Mode (when 'searchkeys' is provided): Executes AutoRAG vector semantic search (Xenova all-MiniLM-L6-v2 + BM25 ranking) over the 3-month Luma public event vault. Directly returns the full detailed content of top matching events (~100 tokens each) formatted into line-numbered Markdown.
2. Live API Pagination Mode (when 'searchkeys' is omitted): Performs a live network request to Luma API (NOT vault), fetching up to 50 events for the specified 'page' and dumping them into line-numbered Markdown.

Every line is numbered ('   1|...', '   2|...') for mandatory line-number citation (e.g. [sourceId, 15-30]).
Locations: 'san_francisco' (旧金山), 'berkeley' (伯克利), 'shanghai' (上海). Multiple locations can be selected. Defaults to ['san_francisco'].
Categories: 'tech', 'ai', 'crypto'. Multiple categories can be selected. Leave empty or omit to query all categories.
Date Constraints: start_date and end_date MUST use strict MM:DD:YY format (e.g., '09:10:26' for Sep 10, 2026). If both are provided, returns events between them. If only one is provided, filters accordingly. If neither is provided, unconstrained.
searchkeys: Keywords or semantic query to search for specific topics/types of events (e.g. 'agent hackathon', 'founder mixer', 'deep learning'). Optional.
limit: Maximum number of events to return when searchkeys is provided (default: 5).
Page: 1-indexed page number (default 1) for live API pagination when searchkeys is omitted.
Presentation rule: When citing or presenting events to the user, you MUST use the exact verbatim event title without renaming, provide the direct event markdown link ([Title](url)), and report the physical location accurately.`,
        inputSchema: {
          type: 'object',
          properties: {
            searchkeys: {
              type: 'string',
              description: "Keywords or question to trigger AutoRAG vector semantic search over the 3-month Luma public event vault. If omitted or empty, falls back to standard live API pagination."
            },
            locations: {
              type: 'array',
              items: {
                type: 'string',
                enum: ['san_francisco', 'berkeley', 'shanghai']
              },
              description: "List of locations to query. Options: 'san_francisco' (旧金山), 'berkeley' (伯克利), 'shanghai' (上海). Multiple locations can be selected. Defaults to ['san_francisco']."
            },
            categories: {
              type: 'array',
              items: {
                type: 'string',
                enum: ['tech', 'ai', 'crypto']
              },
              description: "List of categories to filter. Options: 'tech', 'ai', 'crypto'. Multiple can be selected. Leave empty or omit for all categories."
            },
            start_date: {
              type: 'string',
              description: "Start date filter in strict MM:DD:YY format (e.g., '09:10:26' for Sep 10, 2026). Optional."
            },
            end_date: {
              type: 'string',
              description: "End date filter in strict MM:DD:YY format (e.g., '09:20:26' for Sep 20, 2026). Optional."
            },
            page: {
              type: 'integer',
              description: "Page number (1-indexed, default 1) for live API pagination when searchkeys is omitted.",
              default: 1
            },
            limit: {
              type: 'integer',
              description: "Maximum number of events to return in semantic search mode (default: 5).",
              default: 5
            }
          }
        }
      }
    ]
  };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  if (name === 'get_luma_events') {
    try {
      const response = await fetch('http://127.0.0.1:8004/api/dump-markdown', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(args || {})
      });

      if (!response.ok) {
        const errText = await response.text();
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify({ error: `Luma service responded with ${response.status}`, details: errText })
            }
          ],
          isError: true
        };
      }

      const dumpResult = await response.json();
      return {
        content: [
          {
            type: 'text',
            text: JSON.stringify(dumpResult)
          }
        ]
      };
    } catch (err) {
      return {
        content: [
          {
            type: 'text',
            text: JSON.stringify({ error: err.message })
          }
        ],
        isError: true
      };
    }
  }

  throw new Error(`Tool not found: ${name}`);
});

const transport = new StdioServerTransport();
await server.connect(transport);
console.error('Luma MCP server running on stdio');
