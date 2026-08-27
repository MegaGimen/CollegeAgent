# Networker MCP Server

Local semantic search MCP server for Networker's Obsidian-style markdown vault.

## Overview

This MCP server provides AI agents with the ability to search and traverse a knowledge graph built from markdown files with wikilinks. It uses local embeddings (no API keys required) for semantic search.

## Directory Structure

```
MCP/
├── assets/          # Your Obsidian vault (markdown files with [[wikilinks]])
├── index.json       # Generated index (embeddings + graph)
├── server.js        # MCP server implementation
├── indexer.js       # Index builder
└── package.json
```

## Setup

### 1. Install dependencies

```bash
cd MCP
npm install
```

### 2. Add your vault

Copy your Obsidian vault (or Networker output) to the `assets/` folder:

```bash
cp -r ../vault/example.com_task_123/* ./assets/
```

Or manually place markdown files with `[[wikilinks]]` in `assets/`.

### 3. Build the index

```bash
node indexer.js
```

This will:
- Scan all `.md` files in `assets/`
- Extract wikilinks to build the graph
- Generate embeddings using a local model (~30MB download on first run)
- Save the index to `index.json`

### 4. Start the MCP server

```bash
node server.js
```

## Connecting to Hermes Agent

Add to your `~/.hermes/config.yaml`:

```yaml
mcp_servers:
  networker:
    command: node
    args: ["/home/collegeagent/networker/MCP/server.js"]
```

## Tools

### `search`

Semantic search returning top 5 most relevant notes.

**Input:**
- `query` (string): The question or search query
- `limit` (number, optional): Max results (default: 5)

**Output:**
```json
{
  "query": "authentication architecture",
  "results": [
    {
      "nodeId": "a1b2c3d4e5f6g7h8",
      "title": "Auth Architecture",
      "path": "Auth-Architecture.md",
      "similarity": 0.92,
      "content": "# Auth Architecture\n\n..."
    }
  ],
  "total": 5
}
```

### `read`

Read full content of a specific note by node ID.

**Input:**
- `nodeId` (string): The node ID (content hash)

**Output:**
```json
{
  "nodeId": "a1b2c3d4e5f6g7h8",
  "title": "Auth Architecture",
  "path": "Auth-Architecture.md",
  "content": "# Auth Architecture\n\nFull content here..."
}
```

### `traverse`

Get all nodes connected to a given node via wikilinks.

**Input:**
- `nodeId` (string): The node ID to find connections for

**Output:**
```json
{
  "nodeId": "a1b2c3d4e5f6g7h8",
  "title": "Auth Architecture",
  "totalConnections": 12,
  "outbound": [
    { "nodeId": "...", "title": "Sarah Chen" },
    { "nodeId": "...", "title": "API Design" }
  ],
  "inbound": [
    { "nodeId": "...", "title": "Security Overview" }
  ]
}
```

## How It Works

### Node IDs

Each node ID is a 16-character SHA-256 hash of the filename (without extension). This provides stable, deterministic IDs that don't change unless the file is renamed.

### Semantic Search

1. Query is embedded using the same local model (`all-MiniLM-L6-v2`)
2. Cosine similarity computed against all note embeddings
3. Top K results returned with similarity scores

### Graph Traversal

Wikilinks (`[[Target]]` or `[[Target|Display]]`) are extracted from each file and resolved to node IDs. The `traverse` tool returns both:
- **Outbound**: Notes this note links to
- **Inbound**: Notes that link to this note

## Rebuilding the Index

Run `node indexer.js --force` to rebuild from scratch, or just `node indexer.js` for incremental updates.

## Model Info

- **Embedding model**: `Xenova/all-MiniLM-L6-v2`
- **Size**: ~30MB (downloaded on first run)
- **Dimensions**: 384
- **Max tokens**: 512

The model runs locally via `@xenova/transformers` — no API keys or network calls needed after initial download.
