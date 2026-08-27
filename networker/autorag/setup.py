#!/usr/bin/env python3
"""
Networker AutoRAG Setup — uses the REAL AutoRAG framework.

Reads MCP/assets/*.md, builds AutoRAG corpus + QA parquet files,
runs AutoRAG Evaluator to find the optimal retrieval pipeline,
and extracts the best config for deployment.

Usage:
    python setup.py

Output:
    data/corpus.parquet     — AutoRAG corpus dataset
    data/qa.parquet         — AutoRAG QA dataset (synthetic)
    data/config.yaml        — Evaluation config
    data/trial/             — AutoRAG trial results
    data/best_pipeline.yaml — Extracted optimal pipeline
"""

import json
import os
import re
import shutil
import sys
from datetime import datetime
from pathlib import Path

import numpy as np
import pandas as pd
import yaml

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ASSETS_DIR = os.path.join(BASE_DIR, "..", "MCP", "assets")
PROJECT_DIR = os.path.join(BASE_DIR, "data")
TRIAL_DIR = os.path.join(PROJECT_DIR, "trial")

# ---------------------------------------------------------------------------
# Markdown helpers
# ---------------------------------------------------------------------------

WIKILINK_RE = re.compile(r"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]")


def extract_title(content, filename):
    m = re.search(r"^#\s+(.+)$", content, re.MULTILINE)
    return m.group(1).strip() if m else Path(filename).stem


def extract_source_url(content):
    m = re.search(r"\*\*Source URL\*\*:\s*\[.*?\]\((.*?)\)", content)
    return m.group(1) if m else ""


def extract_user_id(content):
    m = re.search(r"\*\*User ID\*\*:\s*(.+)", content)
    return m.group(1).strip() if m else ""


def extract_course_id(content):
    m = re.search(r"\*\*Course ID\*\*:\s*(.+)", content)
    return m.group(1).strip() if m else ""


def chunk_markdown(content, max_chars=1500, overlap=100):
    sections = re.split(r"\n(?=##\s)", content)
    chunks, current = [], ""
    for sec in sections:
        sec = sec.strip()
        if not sec:
            continue
        if len(current) + len(sec) + 1 > max_chars and current:
            chunks.append(current.strip())
            current = current[-overlap:] + "\n" + sec if overlap else sec
        else:
            current = current + "\n" + sec if current else sec
    return chunks or [content.strip()]


# ---------------------------------------------------------------------------
# Build AutoRAG corpus.parquet
# ---------------------------------------------------------------------------

def build_corpus_parquet(assets_dir, output_path):
    rows = []
    import hashlib

    # Process public markdown files
    for md_file in sorted(Path(assets_dir).rglob("*.md")):
        try:
            content = md_file.read_text(encoding="utf-8")
        except Exception:
            continue

        title = extract_title(content, md_file.name)
        source_url = extract_source_url(content)
        user_id = extract_user_id(content)
        course_id = extract_course_id(content)
        chunks = chunk_markdown(content)
        mtime = datetime.fromtimestamp(md_file.stat().st_mtime)

        file_hash = hashlib.md5(str(md_file).encode()).hexdigest()[:6]
        for i, chunk in enumerate(chunks):
            doc_id = (
                f"{file_hash}_{md_file.stem.replace(' ', '_')[:60]}_{i}"
                if len(chunks) > 1
                else f"{file_hash}_{md_file.stem.replace(' ', '_')[:60]}"
            )
            rows.append({
                "doc_id": doc_id,
                "contents": chunk,
                "metadata": {
                    "last_modified_datetime": mtime,
                    "title": title,
                    "path": md_file.name,
                    "source_url": source_url,
                    "user_id": user_id,
                    "course_id": course_id,
                    "chunk_index": i,
                    "source_type": "public",
                },
            })

    # Process private vaults
    private_vaults_dir = os.path.join(os.path.dirname(assets_dir), "private_vaults")
    if os.path.exists(private_vaults_dir):
        for user_dir in os.listdir(private_vaults_dir):
            index_path = os.path.join(private_vaults_dir, user_dir, "index.json")
            if not os.path.exists(index_path):
                continue
            
            try:
                with open(index_path, "r", encoding="utf-8") as f:
                    index_data = json.load(f)
            except Exception:
                continue
                
            mtime = datetime.fromtimestamp(os.path.getmtime(index_path))
            for node_id, node in index_data.get("nodes", {}).items():
                content = node.get("content", "")
                if not content:
                    continue
                    
                title = node.get("title", "")
                source_url = node.get("url", "")
                path = node.get("path", "")
                course_id = node.get("course_id", "")
                
                # Determine source_type: "personal", "Gmail" vs "course"
                if (
                    node_id.startswith("personal_")
                    or node.get("source") == "personal"
                    or node.get("source_type") == "personal"
                ):
                    source_type = "personal"
                elif (
                    node_id.startswith("gmail_")
                    or node.get("source") == "Gmail"
                    or node.get("source_type") == "Gmail"
                ):
                    source_type = "Gmail"
                else:
                    source_type = "course"
                
                chunks = chunk_markdown(content)
                for i, chunk in enumerate(chunks):
                    doc_id = f"{node_id}_{i}" if len(chunks) > 1 else node_id
                    rows.append({
                        "doc_id": doc_id,
                        "contents": chunk,
                        "metadata": {
                            "last_modified_datetime": mtime,
                            "title": title,
                            "path": path,
                            "source_url": source_url,
                            "user_id": user_dir,
                            "course_id": course_id,
                            "chunk_index": i,
                            "source_type": source_type,
                        },
                    })

    df = pd.DataFrame(rows)
    df.to_parquet(output_path, index=False)
    print(f"✅ Corpus: {len(df)} chunks → {output_path}")
    return df


# ---------------------------------------------------------------------------
# Generate synthetic QA data for AutoRAG evaluation
# ---------------------------------------------------------------------------

def build_qa_parquet(corpus_df, output_path):
    qa_rows = []
    seen_titles = set()

    for _, row in corpus_df.iterrows():
        title = row["metadata"]["title"]
        if title in seen_titles or row["metadata"].get("chunk_index", 0) != 0:
            continue
        seen_titles.add(title)

        # All chunks of same document = retrieval ground truth
        same_file = corpus_df[
            corpus_df["metadata"].apply(lambda m: m.get("title") == title)
        ]["doc_id"].tolist()

        # Ground truth answer = first chunk content
        gt_answer = row["contents"][:500]

        questions = [
            f"What is {title}?",
            f"Tell me about {title}.",
            f"Explain {title.split(' - ')[0].strip()}.",
        ]

        for q in questions:
            qa_rows.append({
                "qid": f"q_{len(qa_rows)}",
                "query": q,
                "retrieval_gt": [same_file],  # 2D list (OR condition)
                "generation_gt": [gt_answer],
            })

    df = pd.DataFrame(qa_rows)
    df.to_parquet(output_path, index=False)
    print(f"✅ QA data: {len(df)} pairs → {output_path}")
    return df


# ---------------------------------------------------------------------------
# Create AutoRAG evaluation config
# ---------------------------------------------------------------------------

def create_eval_config(output_path):
    """
    Config tests multiple retrieval strategies:
      1. BM25 (lexical)
      2. VectorDB with local BGE embeddings (semantic)
      3. Hybrid RRF (combination)
    + minimal generator to complete the pipeline.
    """
    config = {
        "vectordb": [
            {
                "name": "local_chroma",
                "db_type": "chroma",
                "client_type": "persistent",
                "embedding_model": "huggingface_baai_bge_small",
                "collection_name": "networker_vault",
                "path": os.path.join(PROJECT_DIR, "chroma_db"),
            }
        ],
        "node_lines": [
            {
                "node_line_name": "retrieve_node_line",
                "nodes": [
                    {
                        "node_type": "lexical_retrieval",
                        "strategy": {
                            "metrics": [
                                "retrieval_f1", "retrieval_recall",
                                "retrieval_precision", "retrieval_ndcg",
                                "retrieval_mrr",
                            ]
                        },
                        "top_k": 5,
                        "modules": [
                            {"module_type": "bm25"},
                        ],
                    },
                    {
                        "node_type": "semantic_retrieval",
                        "strategy": {
                            "metrics": [
                                "retrieval_f1", "retrieval_recall",
                                "retrieval_precision", "retrieval_ndcg",
                                "retrieval_mrr",
                            ]
                        },
                        "top_k": 5,
                        "modules": [
                            {
                                "module_type": "vectordb",
                                "vectordb": "local_chroma",
                            }
                        ],
                    },
                    {
                        "node_type": "hybrid_retrieval",
                        "strategy": {
                            "metrics": [
                                "retrieval_f1", "retrieval_recall",
                                "retrieval_precision", "retrieval_ndcg",
                                "retrieval_mrr",
                            ]
                        },
                        "top_k": 5,
                        "modules": [
                            {
                                "module_type": "hybrid_rrf",
                                "weight_range": "(4,80)",
                            },
                        ],
                    },
                ],
            },
            {
                "node_line_name": "post_retrieve_node_line",
                "nodes": [
                    {
                        "node_type": "prompt_maker",
                        "strategy": {
                            "metrics": [
                                {"metric_name": "bleu"},
                                {"metric_name": "rouge"},
                            ],
                            "generator_modules": [
                                {
                                    "module_type": "llama_index_llm",
                                    "llm": "openai",
                                    "model": ["gpt-4o-mini"],
                                }
                            ],
                        },
                        "modules": [
                            {
                                "module_type": "fstring",
                                "prompt": (
                                    "Read the passages and answer the question.\n"
                                    "Question: {query}\n"
                                    "Passage: {retrieved_contents}\n"
                                    "Answer: "
                                ),
                            }
                        ],
                    },
                    {
                        "node_type": "generator",
                        "strategy": {
                            "metrics": [
                                {"metric_name": "bleu"},
                                {"metric_name": "rouge"},
                            ]
                        },
                        "modules": [
                            {
                                "module_type": "llama_index_llm",
                                "llm": "openai",
                                "model": "gpt-4o-mini",
                                "temperature": [0.5],
                            }
                        ],
                    },
                ],
            },
        ],
    }

    with open(output_path, "w") as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
    print(f"✅ Config → {output_path}")


# ---------------------------------------------------------------------------
# Create retrieval-only config (no OpenAI needed)
# ---------------------------------------------------------------------------

def create_retrieval_only_config(output_path):
    """Config that ONLY evaluates retrieval methods.
    No generator needed — pure retrieval evaluation."""
    config = {
        "vectordb": [
            {
                "name": "local_chroma",
                "db_type": "chroma",
                "client_type": "persistent",
                "embedding_model": "huggingface_baai_bge_small",
                "collection_name": "networker_vault",
                "path": os.path.join(PROJECT_DIR, "chroma_db"),
            }
        ],
        "node_lines": [
            {
                "node_line_name": "retrieve_node_line",
                "nodes": [
                    {
                        "node_type": "lexical_retrieval",
                        "strategy": {
                            "metrics": [
                                "retrieval_f1", "retrieval_recall",
                                "retrieval_ndcg", "retrieval_mrr",
                            ]
                        },
                        "top_k": 5,
                        "modules": [{"module_type": "bm25"}],
                    },
                    {
                        "node_type": "semantic_retrieval",
                        "strategy": {
                            "metrics": [
                                "retrieval_f1", "retrieval_recall",
                                "retrieval_ndcg", "retrieval_mrr",
                            ]
                        },
                        "top_k": 5,
                        "modules": [
                            {"module_type": "vectordb", "vectordb": "local_chroma"}
                        ],
                    },
                ],
            },
        ],
    }

    with open(output_path, "w") as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
    print(f"✅ Retrieval-only config → {output_path}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--fast", action="store_true", help="Skip QA and evaluation, only rebuild corpus")
    args = parser.parse_args()

    os.makedirs(PROJECT_DIR, exist_ok=True)

    # Clean previous trial
    if not args.fast:
        if os.path.exists(TRIAL_DIR):
            shutil.rmtree(TRIAL_DIR)
        os.makedirs(TRIAL_DIR, exist_ok=True)

    # 1. Build corpus
    print("📖 Building corpus from MCP/assets...")
    if not os.path.isdir(ASSETS_DIR):
        print(f"❌ Assets directory not found: {ASSETS_DIR}")
        sys.exit(1)

    corpus_path = os.path.join(PROJECT_DIR, "corpus.parquet")
    corpus_df = build_corpus_parquet(ASSETS_DIR, corpus_path)

    if args.fast:
        print("⚡ Fast mode: Skipped QA and Evaluation.")
        return

    # 2. Build QA data
    print("❓ Generating synthetic QA data...")
    qa_path = os.path.join(PROJECT_DIR, "qa.parquet")
    build_qa_parquet(corpus_df, qa_path)

    # 3. Create config
    print("📝 Creating AutoRAG evaluation config...")
    config_path = os.path.join(PROJECT_DIR, "config.yaml")
    create_retrieval_only_config(config_path)

    # 4. Run AutoRAG evaluation
    print("🔬 Running AutoRAG evaluation...")
    try:
        from autorag.evaluator import Evaluator

        evaluator = Evaluator(
            qa_data_path=qa_path,
            corpus_data_path=corpus_path,
            project_dir=PROJECT_DIR,
        )
        evaluator.start_trial(config_path)
        print("✅ AutoRAG evaluation complete!")
    except Exception as e:
        print(f"⚠️  AutoRAG evaluation failed: {e}")
        print("   Falling back to retrieval-only mode...")
        # Save a fallback pipeline config using just BM25
        _save_fallback_config()
        return

    # 5. Extract best pipeline
    print("📦 Extracting best pipeline...")
    try:
        from autorag.deploy import extract_best_config

        # Find the trial folder (AutoRAG creates numbered dirs: 0, 1, 2...)
        trial_folders = sorted(
            [d for d in os.listdir(PROJECT_DIR)
             if os.path.isdir(os.path.join(PROJECT_DIR, d)) and d.isdigit()],
            key=int,
        )
        if not trial_folders:
            print("❌ No trial folders found!")
            sys.exit(1)

        trial_path = os.path.join(PROJECT_DIR, trial_folders[-1])
        best_yaml = os.path.join(PROJECT_DIR, "best_pipeline.yaml")
        best_config = extract_best_config(trial_path, best_yaml)
        print(f"🏆 Best pipeline extracted → {best_yaml}")
        print(f"   Config: {json.dumps(best_config, indent=2, default=str)[:500]}")

    except Exception as e:
        print(f"⚠️  Failed to extract best config: {e}")
        _save_fallback_config()


def _save_fallback_config():
    """Save a simple BM25-only pipeline as fallback."""
    fallback = {
        "node_lines": [
            {
                "node_line_name": "retrieve_node_line",
                "nodes": [
                    {
                        "node_type": "lexical_retrieval",
                        "top_k": 5,
                        "modules": [{"module_type": "bm25"}],
                    }
                ],
            },
        ]
    }
    fallback_path = os.path.join(PROJECT_DIR, "best_pipeline.yaml")
    with open(fallback_path, "w") as f:
        yaml.dump(fallback, f, default_flow_style=False)
    print(f"⚠️  Saved fallback config → {fallback_path}")


if __name__ == "__main__":
    main()
