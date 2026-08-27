/**
 * Networker MCP Indexer
 * 
 * Scans the assets folder for Obsidian-style markdown files,
 * extracts wikilinks to build a graph, and generates embeddings
 * for semantic search.
 * 
 * Usage: node indexer.js [--force]
 *   --force: Re-index all files even if unchanged
 *   (default: incremental — only re-embed new/modified files)
 */

import { readFile, writeFile, readdir, stat } from 'fs/promises';
import { join, basename, extname } from 'path';
import { createHash } from 'crypto';

// Configuration
const ASSETS_DIR = new URL('./assets', import.meta.url).pathname;
const INDEX_FILE = new URL('./index.json', import.meta.url).pathname;
const EMBEDDING_MODEL = 'Xenova/all-MiniLM-L6-v2'; // ~30MB, good quality/speed tradeoff
const EMBEDDING_BATCH_SIZE = 8; // reduced from 32 to lower peak memory

// Wikilink regex: [[Target]] or [[Target|Display Text]]
const WIKILINK_RE = /\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g;

/**
 * Generate a stable node ID from filename using content hash
 */
function generateNodeId(filename) {
  const name = basename(filename, extname(filename));
  return createHash('sha256').update(name).digest('hex').slice(0, 16);
}

/**
 * Extract title from markdown content
 */
function extractTitle(content, filename) {
  // Try to extract from first H1
  const h1Match = content.match(/^#\s+(.+)$/m);
  if (h1Match) return h1Match[1].trim();
  
  // Fall back to filename
  return basename(filename, extname(filename));
}

/**
 * Extract wikilinks from content
 */
function extractWikilinks(content) {
  const links = [];
  let match;
  WIKILINK_RE.lastIndex = 0;
  while ((match = WIKILINK_RE.exec(content)) !== null) {
    links.push({
      target: match[1].trim(),
      display: match[2]?.trim() || match[1].trim()
    });
  }
  return links;
}

/**
 * Clean markdown content for embedding
 * Removes frontmatter, code blocks, and excessive whitespace
 */
function cleanForEmbedding(content) {
  // Remove YAML frontmatter
  content = content.replace(/^---[\s\S]*?---\n?/m, '');
  
  // Remove code blocks
  content = content.replace(/```[\s\S]*?```/g, '');
  
  // Remove inline code
  content = content.replace(/`[^`]+`/g, '');
  
  // Remove image links but keep alt text
  content = content.replace(/!\[([^\]]*)\]\([^)]+\)/g, '$1');
  
  // Convert links to just their text
  content = content.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1');
  
  // Remove wikilink syntax, keep display text
  content = content.replace(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g, (_, target, display) => {
    return display || target;
  });
  
  // Normalize whitespace
  content = content.replace(/\s+/g, ' ').trim();
  
  // Truncate to ~2000 chars for embedding (model limit is ~512 tokens)
  if (content.length > 2000) {
    content = content.slice(0, 2000);
  }
  
  return content;
}

/**
 * Scan assets directory for markdown files
 */
async function scanAssets() {
  const files = [];
  
  async function scanDir(dir) {
    const entries = await readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      const fullPath = join(dir, entry.name);
      if (entry.isDirectory()) {
        // Skip hidden directories
        if (!entry.name.startsWith('.')) {
          await scanDir(fullPath);
        }
      } else if (entry.isFile() && entry.name.endsWith('.md')) {
        files.push(fullPath);
      }
    }
  }
  
  await scanDir(ASSETS_DIR);
  return files;
}

/**
 * Build the index (incremental by default, --force for full rebuild)
 */
async function buildIndex(force = false) {
  console.log(`🔍 Scanning assets directory... (${force ? 'FORCE rebuild' : 'incremental'})`);
  const files = await scanAssets();
  console.log(`📄 Found ${files.length} markdown files`);
  
  if (files.length === 0) {
    console.log('⚠️  No markdown files found in assets/');
    console.log('   Copy your Obsidian vault files to assets/ and try again.');
    process.exit(1);
  }
  
  // Load existing index for incremental updates
  let existingIndex = { nodes: {}, edges: [], embeddings: {} };
  try {
    const existing = JSON.parse(await readFile(INDEX_FILE, 'utf-8'));
    existingIndex = existing;
    if (!force) {
      console.log(`📦 Loaded existing index (${Object.keys(existingIndex.nodes || {}).length} nodes)`);
    }
  } catch {
    console.log('📦 No existing index found, building from scratch');
  }

  const existingNodes = existingIndex.nodes || {};
  const existingEmbeddings = existingIndex.embeddings || {};
  const existingMtimes = existingIndex.mtimes || {};
  
  // Phase 1: Parse all files, detect which need re-embedding
  console.log('📖 Parsing markdown files...');
  const index = {
    version: 1,
    model: EMBEDDING_MODEL,
    generatedAt: new Date().toISOString(),
    nodes: {},
    edges: [],
    embeddings: {},
    mtimes: {},  // track file modification times for incremental mode
  };
  
  const titleToId = new Map();
  const filesToEmbed = []; // files that need new embeddings
  
  for (const file of files) {
    const content = await readFile(file, 'utf-8');
    const filename = basename(file);
    const nodeId = generateNodeId(filename);
    const title = extractTitle(content, filename);
    const wikilinks = extractWikilinks(content);
    
    // Get file mtime for change detection
    const fileStat = await stat(file);
    const mtime = fileStat.mtimeMs;
    index.mtimes[nodeId] = mtime;
    
    // Store node (without cleanContent to save memory)
    index.nodes[nodeId] = {
      id: nodeId,
      title,
      path: file.replace(ASSETS_DIR + '/', ''),
      content,
      wikilinks
    };
    
    titleToId.set(title, nodeId);
    titleToId.set(basename(file, '.md'), nodeId);
    
    // Check if we can reuse existing embedding
    const mtimeChanged = force || !existingMtimes[nodeId] || existingMtimes[nodeId] !== mtime;
    const embeddingExists = existingEmbeddings[nodeId];
    const nodeExisted = existingNodes[nodeId];
    
    if (!mtimeChanged && embeddingExists) {
      // Reuse existing embedding — no need to reload model
      index.embeddings[nodeId] = existingEmbeddings[nodeId];
    } else {
      // Mark for embedding generation
      filesToEmbed.push({ nodeId, content });
    }
  }
  
  // Phase 2: Resolve wikilinks to edges
  console.log('🔗 Resolving wikilinks...');
  for (const [nodeId, node] of Object.entries(index.nodes)) {
    for (const link of node.wikilinks) {
      const targetId = titleToId.get(link.target);
      if (targetId && targetId !== nodeId) {
        index.edges.push({ from: nodeId, to: targetId });
      }
    }
  }
  
  // Phase 3: Generate embeddings ONLY for new/changed files
  if (filesToEmbed.length > 0) {
    console.log(`🧮 Generating embeddings for ${filesToEmbed.length} files (${Object.keys(index.embeddings).length} reused)...`);
    
    // Only load the model if we actually need to embed something
    const { pipeline } = await import('@xenova/transformers');
    const embedder = await pipeline('feature-extraction', EMBEDDING_MODEL);
    console.log('✅ Model loaded');
    
    for (let i = 0; i < filesToEmbed.length; i += EMBEDDING_BATCH_SIZE) {
      const batch = filesToEmbed.slice(i, i + EMBEDDING_BATCH_SIZE);
      const texts = batch.map(f => cleanForEmbedding(f.content));
      
      const output = await embedder(texts, { pooling: 'mean', normalize: true });
      
      for (let j = 0; j < batch.length; j++) {
        const sliceStart = j * output.data.length / batch.length;
        const sliceEnd = (j + 1) * output.data.length / batch.length;
        index.embeddings[batch[j].nodeId] = Array.from(output.data.slice(sliceStart, sliceEnd));
      }
      
      // Free batch texts immediately
      texts.length = 0;
      
      if (i > 0 && i % 100 === 0) {
        console.log(`   Processed ${i}/${filesToEmbed.length} files`);
      }
    }
    
    console.log('✅ Embeddings generated');
  } else {
    console.log('✅ All embeddings up to date, no model loading needed!');
  }
  
  // Phase 4: Save index
  console.log('💾 Saving index...');
  await writeFile(INDEX_FILE, JSON.stringify(index, null, 2));
  
  console.log('\n✅ Index built successfully!');
  console.log(`   Nodes: ${Object.keys(index.nodes).length}`);
  console.log(`   Edges: ${index.edges.length}`);
  console.log(`   Embeddings: ${Object.keys(index.embeddings).length} (${filesToEmbed.length} new, ${Object.keys(index.embeddings).length - filesToEmbed.length} reused)`);
  console.log(`   Index file: ${INDEX_FILE}`);
}

// CLI entry point
const force = process.argv.includes('--force');
buildIndex(force).catch(err => {
  console.error('❌ Index build failed:', err);
  process.exit(1);
});
