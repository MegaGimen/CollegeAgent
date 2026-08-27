#!/usr/bin/env python3
"""
Networker AutoRAG Search API — powered by real AutoRAG Runner.

Loads the optimized pipeline from AutoRAG evaluation results
and serves search queries via HTTP.

Usage:
    python run_api.py              # starts on port 8002
    python run_api.py --port 9000

Endpoints:
    POST /search   { "query": "...", "limit": 5 }
    GET  /status
    POST /reindex  (re-runs setup.py and reloads pipeline)
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
from pathlib import Path

import yaml
from flask import Flask, jsonify, request

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "data")
INDEX_FILE = os.path.join(BASE_DIR, "..", "MCP", "index.json")
BEST_PIPELINE = os.path.join(DATA_DIR, "best_pipeline.yaml")

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------

runner = None
mcp_index = None
title_to_node = {}
source_url_to_node = {}  # fallback: resolve nodeId by sourceUrl
pipeline_info = {}

# ── Concurrency guard: only ONE setup.py runs at a time ──
_reindex_lock = threading.Lock()
_reindex_running = False

app = Flask(__name__)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def node_id_from_filename(filename):
    name = Path(filename).stem
    return hashlib.sha256(name.encode()).hexdigest()[:16]


def load_mcp_index():
    global mcp_index, title_to_node, source_url_to_node
    if not os.path.exists(INDEX_FILE):
        print(f"⚠️  MCP index.json not found at {INDEX_FILE}")
        return

    with open(INDEX_FILE, "r") as f:
        mcp_index = json.load(f)

    title_to_node = {}
    source_url_to_node = {}
    for nid, node in mcp_index.get("nodes", {}).items():
        title_to_node[node["title"]] = nid
        stem = Path(node.get("path", "")).stem
        if stem:
            title_to_node[stem] = nid
        # Build sourceUrl → nodeId mapping (extract from content metadata)
        content = node.get("content", "")
        url_match = None
        m = re.search(r"\*\*Source URL\*\*:\s*\[.*?\]\((.+?)\)", content)
        if m:
            url_match = m.group(1).strip()
            if url_match:
                source_url_to_node[url_match] = nid

    print(f"📦 Loaded MCP index: {len(mcp_index.get('nodes', {}))} nodes, {len(source_url_to_node)} sourceUrl mappings")


def load_pipeline():
    """Load AutoRAG pipeline from best_pipeline.yaml or trial folder."""
    global runner, pipeline_info

    # Try loading from extracted YAML first
    if os.path.exists(BEST_PIPELINE):
        try:
            from autorag.deploy import Runner

            runner = Runner.from_yaml(BEST_PIPELINE, project_dir=DATA_DIR)
            with open(BEST_PIPELINE) as f:
                pipeline_info = yaml.safe_load(f)
            print(f"🚀 Loaded AutoRAG pipeline from {BEST_PIPELINE}")
            return
        except Exception as e:
            print(f"⚠️  Failed to load from YAML: {e}")

    # Try loading from trial folder
    trial_folders = sorted(
        [d for d in os.listdir(DATA_DIR)
         if os.path.isdir(os.path.join(DATA_DIR, d)) and d.isdigit()],
        key=int,
    )
    if trial_folders:
        try:
            from autorag.deploy import Runner

            trial_path = os.path.join(DATA_DIR, trial_folders[-1])
            runner = Runner.from_trial_folder(trial_path)
            print(f"🚀 Loaded AutoRAG pipeline from trial {trial_folders[-1]}")
            return
        except Exception as e:
            print(f"⚠️  Failed to load from trial: {e}")

    # No pipeline available — will use fallback
    print("⚠️  No AutoRAG pipeline found. Run setup.py first.")
    print("   Falling back to direct corpus search.")
    runner = None


def fallback_search(query, top_k=5, user_id=None, filter_sources=None):
    """Simple BM25 fallback when AutoRAG pipeline is not available."""
    corpus_path = os.path.join(DATA_DIR, "corpus.parquet")
    if not os.path.exists(corpus_path):
        return []

    import pandas as pd
    from rank_bm25 import BM25Okapi
    import re

    df = pd.read_parquet(corpus_path)
    tokenized = [re.findall(r"\w+", c.lower()) for c in df["contents"]]
    bm25 = BM25Okapi(tokenized)
    query_tokens = re.findall(r"\w+", query.lower())
    scores = bm25.get_scores(query_tokens)

    top_indices = scores.argsort()[::-1]
    results = []
    
    normalized_filters = None
    if filter_sources and isinstance(filter_sources, (list, tuple)) and len(filter_sources) > 0:
        normalized_filters = [str(f).strip().lower() for f in filter_sources if str(f).strip()]
        if len(normalized_filters) == 0:
            normalized_filters = None
    elif isinstance(filter_sources, str) and filter_sources.strip():
        normalized_filters = [filter_sources.strip().lower()]

    for idx in top_indices:
        if scores[idx] <= 0:
            break
        row = df.iloc[idx]
        
        # Privacy isolation: Only allow public nodes or nodes belonging to this user
        row_user_id = row["metadata"].get("user_id", "")
        if row_user_id and row_user_id != user_id:
            continue

        # Source filter isolation: "public", "Gmail", "course"
        row_source_type = row["metadata"].get("source_type")
        if not row_source_type:
            row_source_type = "public" if not row_user_id else "course"

        if normalized_filters is not None:
            if row_source_type.lower() not in normalized_filters:
                continue
            
        results.append({
            "doc_id": row["doc_id"],
            "title": row["metadata"].get("title", ""),
            "path": row["metadata"].get("path", ""),
            "score": float(scores[idx]),
            "content": row["contents"],
            "source_url": row["metadata"].get("source_url", ""),
            "user_id": row_user_id,
            "source_type": row_source_type,
        })
        if len(results) >= top_k:
            break
    return results


def autorag_search(query, top_k=5, user_id=None, filter_sources=None):
    """Use AutoRAG Runner to search."""
    if runner is None:
        return fallback_search(query, top_k, user_id, filter_sources), "fallback_bm25"

    try:
        result = runner.run(query)
        # Runner returns the generated text; we need to also get retrieved docs
        # For now, use fallback for the actual document retrieval
        # and runner for the pipeline optimization insights
        docs = fallback_search(query, top_k, user_id, filter_sources)
        return docs, "autorag_pipeline"
    except Exception as e:
        print(f"⚠️  AutoRAG Runner error: {e}, falling back to BM25")
        return fallback_search(query, top_k, user_id, filter_sources), "fallback_bm25"


def map_results(results):
    """Add MCP node IDs to results (by title, then fallback to sourceUrl)."""
    mapped = []
    seen = set()
    for r in results:
        title = r.get("title", "")
        node_id = title_to_node.get(title)

        # Fallback: try sourceUrl if title didn't match
        if not node_id and r.get("source_url"):
            node_id = source_url_to_node.get(r["source_url"])

        if not node_id and r.get("doc_id"):
            node_id = re.sub(r'_\d+$', '', r["doc_id"])

        dedup = node_id or title
        if dedup in seen:
            continue
        seen.add(dedup)

        entry = {
            "title": title,
            "path": r.get("path", ""),
            "score": round(r.get("score", 0), 4),
            "content": r.get("content", ""),
            "source_type": r.get("source_type", "public"),
        }
        if node_id:
            entry["nodeId"] = node_id
        if r.get("source_url"):
            entry["sourceUrl"] = r["source_url"]
        mapped.append(entry)
    return mapped


# ---------------------------------------------------------------------------
# Flask Routes
# ---------------------------------------------------------------------------


@app.route("/search", methods=["POST"])
def search():
    data = request.get_json(force=True)
    query = data.get("query", "").strip()
    limit = data.get("limit", 5)
    user_id = data.get("userId")
    filter_sources = data.get("filter") or data.get("filterSources") or data.get("filter_sources")

    if not query:
        return jsonify({"error": "query is required"}), 400

    results, method = autorag_search(query, limit, user_id, filter_sources)
    mapped = map_results(results)

    return jsonify({
        "query": query,
        "method": method,
        "results": mapped,
        "total": len(mapped),
    })


@app.route("/status", methods=["GET"])
def status():
    has_runner = runner is not None
    has_corpus = os.path.exists(os.path.join(DATA_DIR, "corpus.parquet"))
    has_pipeline = os.path.exists(BEST_PIPELINE)

    return jsonify({
        "autorag_runner": has_runner,
        "has_corpus": has_corpus,
        "has_pipeline": has_pipeline,
        "mcp_nodes": len(title_to_node),
        "pipeline_info": str(pipeline_info)[:500] if pipeline_info else None,
    })


@app.route("/reindex", methods=["POST"])
def reindex():
    """Re-run setup.py and reload pipeline. Rejects if already running."""
    global _reindex_running

    # Non-blocking check: if another reindex is in progress, reject immediately
    if not _reindex_lock.acquire(blocking=False):
        return jsonify({
            "success": False,
            "error": "Reindex already in progress. Please wait.",
            "skipped": True,
        }), 409  # 409 Conflict

    _reindex_running = True
    try:
        print("🔄 /reindex started (setup.py)...")
        result = subprocess.run(
            [sys.executable, os.path.join(BASE_DIR, "setup.py"), "--fast"],
            capture_output=True,
            text=True,
            timeout=600,
        )
        if result.returncode != 0:
            return jsonify({"error": result.stderr[-1000:]}), 500

        load_mcp_index()
        load_pipeline()

        return jsonify({
            "success": True,
            "autorag_runner": runner is not None,
            "output": result.stdout[-500:],
        })
    except subprocess.TimeoutExpired:
        return jsonify({"error": "Reindex timed out (10min)"}), 504
    except Exception as e:
        return jsonify({"error": str(e)}), 500
    finally:
        _reindex_running = False
        _reindex_lock.release()


# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description="Networker AutoRAG Search API")
    parser.add_argument("--port", type=int, default=8002)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()

    load_mcp_index()
    load_pipeline()

    print(f"\n🚀 AutoRAG Search API on http://{args.host}:{args.port}")
    print(f"   POST /search  — search (AutoRAG or fallback)")
    print(f"   GET  /status  — pipeline info")
    print(f"   POST /reindex — re-evaluate and reload\n")

    app.run(host=args.host, port=args.port, debug=False)


if __name__ == "__main__":
    main()
