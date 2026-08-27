# CollegeAgent Ecosystem Architecture & AGENTS Protocol

This document merges the architectural design and operational protocols for the **CollegeAgent** project, encompassing the Core Agent, Canvas MCP, and Networker MCP.

---

**最高指示：必须使用这个命令编译flutter前端**：flutter build web --pwa-strategy=none --base-href /collegeagent/

## 1. Project Architecture & Microservices

The ecosystem is divided into three primary interconnected components:

### A. CollegeAgent (Core Orchestrator)
The user-facing AI assistant that orchestrates tools, manages conversational context, and persists user memory.
- **Frontend/Backend**: Flutter application and Node.js server.
- **Memory System**: Automatically injects "Current User Memory" into the context. Uses `insert` and `str_replace` tools to proactively track user facts, schedules, and behavioral preferences.
- **Decision Engine**: Intelligently routes user queries to Canvas API (for academics), Networker AutoRAG (for campus knowledge), or Live Web Search.

### B. Canvas MCP (Academic Data & Private Graph Builder)
Provides a bridge to the University's Canvas LMS while seamlessly building personalized knowledge graphs.
- **Anti-Hallucination Caches**: Maintains `userCourseCache`, `userModuleCache`, and `userPageCache` to strictly restrict access to courses/modules the agent has explicitly discovered.
- **Synchronous Graph Integration**: When `get_page_content` is called, it fetches the Canvas page, parses 1-hop outbound links, and **synchronously** crawls external dependencies using Networker's Playwright engine.
- **Private Vaults**: Stores all parsed Canvas data and 1-hop external links in a user-specific `index.json` vault for downstream semantic retrieval.

### C. Networker MCP (AutoRAG & Public Graph Crawler)
Provides public knowledge retrieval and robust web crawling.
- **AutoRAG Search API**: Evaluates and routes queries across BM25 (lexical), VectorDB (semantic via BAAI/bge-small), and Hybrid RRF pipelines. (Runs on port `8002`).
- **Graph Crawling (`crawler.js`)**: A headless Playwright script with WAF-bypass (Cloudflare/CDN) capabilities. It resolves all extracted links to **absolute URLs** (preventing Markdown relative-path bugs in Obsidian).
- **Cross-Service Utilization**: Networker's crawler is directly imported by the Canvas MCP to ensure consistent anti-bot evasion and DOM-to-Markdown parsing across the entire ecosystem.

### D. Gmail Integration & Private Vault Multi-Source Model
- **Multi-Source Vault Structure**:
  - **Public Vault (`"public"`)**: Public campus knowledge, student guides, web crawler results.
  - **Course Vault (`"course"`)**: User Canvas course pages, modules, syllabus, assignments.
  - **Gmail Vault (`"Gmail"`)**: User Gmail inbox emails (Markdown-converted with 1-hop outbound crawled nodes).
  - **Personal Vault (`"personal"`)**: User-uploaded documents (PDF, PPTX, DOCX, XLSX, etc) converted to Markdown.
- **Auto-Sync Engine**: Syncs active users' Gmail mailboxes hourly in the background and on demand via frontend button. Outbound links in emails are automatically crawled (1-hop) into the user's private vault.
- **Search Filtering**: The `search` tool supports a `filter` parameter (array of strings):
  - `[]` (default): Global search across all 4 sources (Public Vault + Course Private Vault + Gmail Private Vault + Personal Vault).
  - `["public"]`: Search public campus knowledge and guides.
  - `["Gmail"]`: Search only private Gmail emails and their 1-hop nodes.
  - `["course"]`: Search only private Canvas courseware and academic pages.
  - `["personal"]`: Search only private user-uploaded documents (PDFs, PPTs, etc).

---

## 2. Core Agent Operational Rules (CollegeAgent)

1. **Always search first (Mandatory Tool Execution)**: All queries regarding courses, course modules/pages, assignments, syllabus, grades, emails, university policies, or academic requirements MUST strictly rely on context retrieved via tools. NEVER rely on built-in model memory or guess any course content or policy details.
   - **Canvas LMS Queries** (courses, modules, pages, grades): Use Canvas MCP (`get_page_content`, `get_modules`, `get_assignments`).
   - **Personal Vault Queries** (user uploaded PDF, PPTX, DOCX, files): Use AutoRAG (`search(query, filter=["personal"])` -> `read(sourceId)`).
   - **Campus Knowledge Queries** (policies, campus resources): Use AutoRAG (`search(query, filter=["public"])` -> `read`/`expand`).
   - **Gmail Queries** (emails, communications, incoming notices): Use AutoRAG (`search(query, filter=["Gmail"])` -> `read`/`expand`).
   - **Cross-Domain / General Queries**: Use AutoRAG (`search(query, filter=[])`). Note that `search` only searches explicitly cached pages (modules/pages), Gmail, and public resources. It is NOT a panacea and will NOT find Course Syllabus or Announcements unless they were already read.
   - **Public / Live Web Queries**: Use Web Search (`web_search` -> `expand(url)`).
2. **Mandatory Search & Reading Workflow**:
   - **Course Schedule & Syllabus Fallback SOP**: When looking for course schedules or meeting times, you MUST follow this sequence for EACH course: 1. `get_syllabus` -> 2. `get_modules` -> 3. If syllabus and modules lack schedule info, you **MUST** call `get_announcements` to check for first-week schedules. Do not skip checking announcements!
   - **Vault Search (`search`)**: `search(query, filter)` returns ONLY short 250-character preview snippets and does NOT contain complete document text or line numbers. You **MUST NOT** answer the user's question directly from `search` snippets. You **MUST** call `read(sourceId)` on the relevant result node(s) to fetch the full document containing explicit line numbers (`  1|...`, `  2|...`) before generating your answer.
   - **Web Search (`web_search`)**: `web_search(topic)` only returns search engine snippets. You **MUST** call `expand(url)` to read the full page content.
3. **Citation Rules (CRITICAL - STRICT MANDATORY LINE NUMBERS)**:
   - **MANDATORY Line Numbers & Line Ranges**: Every factual claim MUST end with a numeric citation containing the exact source ID AND specific line numbers or line range, e.g., `[1, 45-62]` or `[2, 12]`.
   - **STRICTLY PROHIBIT Bare `[x]` Citations**: You MUST NEVER output bare numeric citations without line numbers like `[1]`, `[2]`, `[8]`, or `[10]`. Citations lacking line numbers are strictly forbidden and considered invalid citations.
   - **Line Numbering Across All Tools**: All tools returning full content (`read`, `expand`, `get_page_content`, `get_syllabus`, `get_announcement_detail`, `get_assignment_detail`, `get_discussion_detail`, `read_file_content`, etc.) provide explicit line number prefixes (`  1|...`, `  2|...`). You MUST use the exact line numbers from the tool output to construct your citations (e.g., `[8, 1-4]`, `[10, 22-23]`).
   - **NEVER Cite `search` Directly**: `search` snippets do not have complete text or line numbers. You MUST call `read(sourceId)` first and cite the line numbers from the `read` output.
   - **Never Invent sourceId or Line Numbers**: Only cite valid source IDs from your session routing table and real line numbers from tool responses.
   - **Never Cite Bare URLs**: You must follow links using tools and cite the read content with line numbers.
4. **Information Timeliness**: Always verify the academic year (e.g., 2025-2026). If a page is archived, follow its outbound links or run a new search with the current year appended.
5. **Memory Usage**: Save user facts and behavioral feedback (corrections, preferences) silently using the memory tools. Do not announce memory writes to the user.
6. **Sequential Module Progress Handling**: 如果遇到有顺序解锁要求（如 `require_sequential_progress` 为 true 或 Module 内存在必须按顺序阅读的 Sections/Pages，例如看完 Section 1 才能看完 Section 2、Section 3 等），而用户明确要求把这个 Module 的内容全部看/处理完，核心 Agent **必须且应当遵从用户的指令，按照顺序依次调用 `get_page_content` 获取并处理每个 Section/Page 的内容**，直至整个 Module 全部处理完毕。

---

## 3. Networker & AutoRAG Specifications

### Service Details
- **Systemd Service**: `networker_mcp.service`
- **Port**: `127.0.0.1:8002`
- **API Endpoints**: 
  - `POST /search` - Search knowledge base
  - `POST /reindex` - Re-evaluate AutoRAG pipelines and hot-reload index
- **Auto-Reloading**: Calling `promote-to-knowledge-base` automatically rebuilds the graph index and triggers a `:8002/reindex`.

### Crawl Blocking (Do NOT Retry)
When `expand(url)` returns `[BLOCKED]` (due to Cloudflare, Captchas, or 403s):
- **NEVER retry the same URL.**
- Use the `web_search` snippet instead or find an alternative source.

---

## 4. Canvas Integration Details

- **Two-Tier Tool Paradigm (List vs Detail)**: Canvas tools are strictly decoupled into List and Detail variants to prevent context flooding.
  - **List Tools** (e.g., `list_courses`, `get_assignments`, `get_announcements`, `get_files`): Return highly abbreviated arrays of items (IDs, titles, dates only). NEVER assume a List tool returns full content (like syllabus text or assignment rubrics). You must use these first to discover item IDs.
  - **Detail Tools** (e.g., `get_syllabus`, `get_assignment_detail`, `get_announcement_detail`, `read_file_content`): Demand specific numeric IDs (e.g., `assignmentId`). They return granular, full-length content for a single item.
- **Anti-Hallucination Caches**: Detail tools strictly enforce valid IDs against memory caches populated by List tools. You CANNOT guess or hallucinate `assignmentId`, `announcementId`, or `fileId`. You MUST explicitly call the corresponding List tool in the same session before calling a Detail tool.
- **Universal Document Reading**: The `read_file_content` tool supports reading `pdf`, `docx`, `pptx`, `xlsx`, `csv` formats, bypassing normal web restrictions. Use this when the user needs you to summarize a lecture slide or syllabus document.
- **Input Constraints**: Tools requiring `courseId` must use the exact numeric ID (e.g., `1555334`), never list indexes.
- **Student API Limitations & Quiz Handling**: Students DO NOT have API permissions to fetch quiz questions or exam content directly. NEVER attempt to read the content of a quiz. However, you MUST use the `get_quizzes` tool (or check the `html_url` inside module items) to retrieve the HTML link (`html_url`) for the quiz. Always remember to proactively provide this link to the user so they can jump directly to the browser to take the quiz.
- **Graph Alignment**: The output of `get_page_content` perfectly mirrors the `expand(nodeId)` output from Networker. It returns the central node's content along with the fully populated `neighbors` array representing all 1-hop dependencies.
- **Handling `cached=true` vs `cached=false` in `get_page_content`**:
  - **When `cached=false`**: `get_page_content` returns immediately with the main page content, while an asynchronous 1-hop background crawl task is launched. Answer the user's question using the immediately returned main page content first. If 1-hop neighbor details are explicitly required for a complete answer, inform the user that 1-hop background processing is in progress, or query/read the page again once the task completes.

---

## 5. Development & Troubleshooting Knowledge (Post-Mortems)

### A. Vault Data Overwrite / Race Conditions (August 2026)
- **Symptom**: When performing batch node insertions (e.g. "Join personal graph" for multiple courses/pages simultaneously), many pages failed to appear in `index.json`.
- **Root Cause**: Node.js and MCP concurrency. Multiple concurrent `get_page_content` requests were reading the same `index.json`, modifying it in memory, and writing it back. The parallel writes caused massive data overwrite (last write wins).
- **Solution/Rule**: **Never use concurrent background async loops to mutate JSON vaults.** Always use sequential queues (e.g. `for...of` with `await`) when performing batch writes via MCP tools to ensure `index.json` read/write atomicity.

### B. Playwright & Node.js SIGTERM Zombie Processes (August 2026)
- **Symptom**: `systemctl restart networker` hangs indefinitely, locking up deployment pipelines.
- **Root Cause**: When a Chromium socket disconnects unexpectedly (e.g., EPIPE / Broken Pipe), Playwright's default `SIGTERM` handler hangs forever trying to await `browser.close()` over a dead websocket.
- **Solution/Rule**: 
  - **Node.js Level**: Always implement a manual `SIGTERM` and `SIGINT` handler with a strict `setTimeout` fallback (e.g. 5 seconds) that calls `process.exit(1)`. Do not rely solely on Playwright's graceful shutdown.
  - **Systemd Level**: Ensure backend services have a hard stop limit using `TimeoutStopSec=10` in their `.service` file.

### C. Agent Deadlock (假死) via SSE Stream Stalls (August 2026)
- **Symptom**: The agent enters a "thinking" state, returns an empty message, and the UI input box becomes permanently stuck in a responding state.
- **Root Cause**: The Node.js `fetch` connection to the DeepSeek API lacked an idle timeout. When the API stalled mid-stream without terminating the TCP connection, `await reader.read()` hung infinitely. The backend never emitted a `[DONE]` event, causing the frontend UI (`_sending` state) to remain locked forever. Furthermore, MCP tools (like Canvas API fetches) lacked timeouts, which could also stall the tool execution loop.
- **Solution/Rule**:
  - Always wrap streaming LLM API `fetch` calls with an `AbortController` and an **idle timeout** (e.g., 30 seconds) that resets on every chunk received.
  - Always enforce a maximum execution time (`Promise.race`) for MCP tool calls to prevent misbehaving external endpoints from freezing the main agent orchestrator.

## 6. Communication Style (CRITICAL STRICT RULE)

**NEVER USE EXCLAMATION MARKS (!)**. ALL responses MUST NOT contain any exclamation marks whatsoever. Keep the tone completely flat, objective, and devoid of AI flattery or enthusiasm. This is a hard constraint requested by the user.
