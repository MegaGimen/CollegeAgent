# CollegeAgent

An autonomous campus life management agent built for UC Berkeley students. It has native Canvas LMS integration and a custom AI infrastructure pipeline that scrapes websites into navigation graphs the agent can search and walk.

Ask it about a deadline, a syllabus, an email from a professor, a campus policy or a hackathon this weekend. It answers from what it has actually read, and every claim carries a citation down to the line.

## How it fits together

```
                      Flutter app (web / Android)
                                │
                       Core agent  :4093
              tool loop · memory · line-level citations
                                │  MCP
        ┌───────────────┬───────┴────────┬────────────────┐
   Canvas MCP      Networker MCP      Luma MCP     Memory / Calendar MCP
   courses,        search · read ·    events in     user facts,
   modules,        expand over the    SF, Berkeley  Google Calendar
   files, grades   knowledge graph    and Shanghai
        │               │
        │        ┌──────┴───────┐
        │   graph index     AutoRAG API  :8002
        │   nodes · edges   BM25 · vector · hybrid
        │   · embeddings
        │               ▲
        └── 1-hop ──► Networker crawler  :4090
            links     Playwright → Markdown vault with [[wikilinks]]
```

## The infrastructure

### Networker: websites as graphs

`networker/` turns a website into a graph. A queue-driven Playwright crawler walks a site page by page. Each page becomes a Markdown file, and each link between pages becomes a `[[wikilink]]`, so a finished crawl is a folder that opens directly as an Obsidian vault.

- Every crawl is an isolated background task that can be watched and aborted on its own.
- Links are resolved to absolute URLs, and a pending link is labelled with its anchor text until the page itself has been visited.
- A ban list keeps the crawler out of login pages, feeds and upload folders.
- A dashboard streams logs over SSE and draws the finished graph.

### The graph index

`networker/MCP/indexer.js` compiles a vault into one `index.json`: nodes (title, path, content, outgoing links), edges (`from` → `to`) and a local embedding for every node. No API key is needed to build it. The index committed here covers public UC Berkeley pages: 292 nodes and 6,113 edges.

The agent reaches the graph through three MCP tools:

| Tool | What it returns |
|---|---|
| `search(query, filter)` | Short previews of the best-matching nodes |
| `read(sourceId)` | The full node, with line numbers |
| `expand(nodeId)` | The node together with its 1-hop neighbours |

### Four vaults, one search

Search runs over four sources, selected with `filter`:

| Vault | Content |
|---|---|
| `public` | Campus sites crawled by Networker |
| `course` | Canvas pages the student has opened, plus the pages they link to |
| `Gmail` | The student's mail, converted to Markdown, plus linked pages |
| `personal` | Uploaded PDF, PPTX, DOCX and XLSX files |

The last three are private and per user. They live under `networker/MCP/private_vaults/`, which is never committed.

Pages pulled in one hop out from a course page or an email are scraped through a self-hosted Firecrawl, with the hosted Firecrawl API as a fallback.

### AutoRAG retrieval

`networker/autorag/` evaluates lexical (BM25), semantic (vector) and hybrid pipelines against the index, keeps the best one, and serves it over HTTP on port 8002. `POST /reindex` rebuilds and hot-reloads it after the graph changes.

### Canvas MCP

`canvas/` connects the agent to Canvas LMS.

- Tools come in pairs: list tools return ids and titles, detail tools return one full item. This keeps a course from flooding the context.
- Detail tools only accept ids that a list tool has already returned in the same session, so the model cannot invent a course or assignment id.
- Opening a Canvas page also crawls the pages it links to, one hop out, and adds all of it to the student's course vault.
- PDF, PPTX, DOCX and XLSX course files are parsed into line-numbered text.
- Deadlines are converted from Canvas's UTC timestamps to Pacific Time.

### Core agent

`collegeagent/` holds the Node.js orchestrator and the Flutter client.

- An MCP manager runs the tool loop, with a time limit on every tool call and an idle timeout on the model stream so a stalled connection cannot freeze a session.
- Every answer has to cite `[sourceId, lines]`, taken from tool output that carries line numbers.
- User memory is stored with versions and edited by the agent through `insert` and `str_replace`.
- Sessions can be forked for sub-agents.
- The Flutter app shows the chat with tool calls and citations, the knowledge graph, the personal vault, Canvas courses, Gmail and Luma events.

### Review mode

Pick a Canvas course and tick the files to review. The session is bound to those files and stays on them: it explains concepts, summarises the key points and quizzes you, and names the file and page each point comes from.

### Luma events

`luma/` keeps a rolling three-month vault of public events in San Francisco, Berkeley and Shanghai, synced hourly, with semantic search over it and a live API mode.

## Repository layout

```
collegeagent/   core agent server, MCP manager, memory, Flutter app
canvas/         Canvas MCP server, document parser, dashboard
networker/      graph crawler, MCP server and indexer, AutoRAG API
luma/           Luma event vault and MCP server
gbrain/         vendored copy of GBrain (see Third-party code)
*.js, *.py      one-off test and patch scripts from development
AGENTS.md       architecture notes and operating rules for the agent
```

## Running it

Requirements: Node.js 24, Python 3.10 or newer, Flutter for the client, Chromium for Playwright, and Docker if you self-host Firecrawl.

```bash
# keys
cp .env.example collegeagent/.env      # then fill it in

# graph crawler and dashboard
cd networker && npm install && node server.js              # :4090

# build the graph index, then serve retrieval
cd networker/MCP && npm install && node indexer.js
cd networker/autorag && pip install -r requirements.txt && python run_api.py   # :8002

# Canvas dashboard, Luma events
cd canvas && npm install && node server.js                 # :4091
cd luma && npm install && node server.js                   # :8004

# core agent
cd collegeagent && npm install && node server.js           # :4093

# client
cd collegeagent/flutter_app && flutter build web --pwa-strategy=none --base-href /collegeagent/
```

Secrets are read from the environment and nothing is hard-coded. See `.env.example` for the list.

## Third-party code

- `gbrain/` is a vendored copy of [GBrain](https://github.com/garrytan/gbrain) by Garry Tan, MIT licensed. Its own `LICENSE` is kept in that folder.
- Crawling uses [Playwright](https://playwright.dev) and [Firecrawl](https://github.com/firecrawl/firecrawl).
- Retrieval evaluation uses [AutoRAG](https://github.com/Marker-Inc-Korea/AutoRAG).

## License

MIT. See [LICENSE](LICENSE).
