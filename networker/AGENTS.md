# Networker AGENTS.md

## 服务概览

### `networker_mcp` — AutoRAG 搜索 API

| 字段 | 值 |
|------|-----|
| systemd 服务名 | `networker_mcp.service` |
| 端口 | `127.0.0.1:8002` |
| 工作目录 | `/home/collegeagent/networker/autorag/` |
| 启动命令 | `python3 run_api.py --host 127.0.0.1 --port 8002` |
| 开机自启 | 已启用 (`enabled`) |
| 状态检查 | `systemctl status networker_mcp` |
| 查看日志 | `journalctl -u networker_mcp -f` |

#### 功能

为 Networker MCP 的 `search` 工具提供检索后端。使用真正的 **AutoRAG** 框架 ([Marker-Inc-Korea/AutoRAG](https://github.com/Marker-Inc-Korea/AutoRAG)) 自动评估多种检索方法（BM25 / VectorDB+BGE / Hybrid），选择最优方案。

#### AutoRAG 评估的方法

- **BM25** — 关键词检索 (lexical retrieval)
- **VectorDB (Chroma + BAAI/bge-small-en-v1.5)** — 语义检索 (semantic retrieval)
- **Hybrid RRF** — 混合检索 (可选)

#### API 端点

- `POST /search` — 搜索知识库（`{ "query": "...", "limit": 5 }`）
- `GET  /status` — 查看当前 pipeline 和 corpus 信息
- `POST /reindex` — 重新运行 AutoRAG 评估 + 热重载

#### 环境变量

- `AUTORAG_API_URL` — MCP server.js 读取，默认 `http://127.0.0.1:8002`

---

## 架构

```
MCP Client (hermes-agent / Claude Desktop)
           │ stdio
    MCP/server.js
    ┌──────────────────────┐
search ──► AutoRAG API :8002  (BM25 + VectorDB, auto-evaluated)
         └─► + outboundLinks (agent智能选择深入)
read   ──► index.json + outboundLinks
```

## 自动热重载

调用 `POST /api/tasks/:id/promote-to-knowledge-base` 时，server.js 自动触发：

1. MCP graph index 重建 (`node indexer.js --force`)
2. AutoRAG 检索索引重建 (`POST :8002/reindex`)

## 重新评估

当 MCP/assets 内容变化后：

```bash
curl -X POST http://127.0.0.1:8002/reindex
```

或手动运行 AutoRAG 评估：

```bash
cd /home/collegeagent/networker/autorag
python3 setup.py
systemctl restart networker_mcp
```

## AutoRAG 参考

- 安装方式: `pip install AutoRAG` (v0.3.22)
- Trial 结果: `autorag/data/0/` (评估详情)
- 最优 Pipeline: `autorag/data/best_pipeline.yaml`

## Graph Crawling (expand 与 Canvas 联动)

- **`crawler.js`**: 基于 Playwright 封装的同步 HTML 爬虫，具备反爬机制绕过能力，用于深度抓取网页及其一跳 (1-hop) 依赖节点。
- **强制绝对路径转换**: 在 DOM 解析为 Markdown 的阶段，系统会严格地将所有提取到的相对 URL（`href` / `src`）解析为绝对路径 (`new URL(href, base)`)。这避免了下游客户端（如 Obsidian）在点击链接时误将无协议头的相对路径当作本地 Vault 内部文件而错误地自动创建空文件。
- **跨微服务调用**: Canvas MCP (获取个人课件) 直接导入并调用了本微服务 (`networker`) 下的 `crawler.js` 模块，确保内部节点信息展开抓取的过程与公网 Web 搜索抓取具备完全一致的功能基线与抗屏蔽能力。
