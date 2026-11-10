import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const MEMORIES_DIR = path.join(__dirname, 'memories');
const VERSIONS_DIR = path.join(MEMORIES_DIR, 'versions');
export const MAX_VERSIONS = 20;

function ensureVersionsDir() {
  if (!fs.existsSync(VERSIONS_DIR)) {
    fs.mkdirSync(VERSIONS_DIR, { recursive: true });
  }
}

function safeId(userId) {
  return String(userId).replace(/[^a-zA-Z0-9_\-.]/g, '_');
}

export function getVersionsFilePath(userId) {
  ensureVersionsDir();
  return path.join(VERSIONS_DIR, `${safeId(userId)}.json`);
}

export function getVersions(userId) {
  const fp = getVersionsFilePath(userId);
  let versions = [];
  if (fs.existsSync(fp)) {
    try {
      const data = JSON.parse(fs.readFileSync(fp, 'utf-8'));
      if (Array.isArray(data)) versions = data;
    } catch (_) {}
  }
  if (versions.length === 0) {
    const memFp = path.join(MEMORIES_DIR, `${safeId(userId)}.md`);
    if (fs.existsSync(memFp)) {
      try {
        const text = fs.readFileSync(memFp, 'utf-8');
        if (text && text.trim().length > 0) {
          const initSnapshot = {
            id: `v_${Date.now()}_init`,
            version: 1,
            timestamp: new Date().toISOString(),
            source: 'initial',
            summary: 'Initial Memory State',
            content: text,
            charCount: text.length,
            lineCount: text.split('\n').length,
          };
          versions = [initSnapshot];
          fs.writeFileSync(fp, JSON.stringify(versions, null, 2), 'utf-8');
        }
      } catch (_) {}
    }
  }
  return versions;
}

export function addSnapshot(userId, content, source, summary) {
  if (content == null) return null;
  const fp = getVersionsFilePath(userId);
  let versions = getVersions(userId);

  // If there is an existing memory file and versions is empty, snapshot the baseline first
  const memFp = path.join(MEMORIES_DIR, `${safeId(userId)}.md`);
  if (versions.length === 0 && fs.existsSync(memFp) && source !== 'initial') {
    try {
      const initialContent = fs.readFileSync(memFp, 'utf-8');
      if (initialContent && initialContent !== content) {
        versions.push({
          id: `v_${Date.now() - 1000}_init`,
          version: 1,
          timestamp: new Date(Date.now() - 1000).toISOString(),
          source: 'initial',
          summary: 'Initial Memory State',
          content: initialContent,
          charCount: initialContent.length,
          lineCount: initialContent.split('\n').length,
        });
      }
    } catch (_) {}
  }

  // Avoid duplicate back-to-back identical snapshots with same content and source
  if (versions.length > 0) {
    const last = versions[versions.length - 1];
    if (last.content === content && last.source === source) {
      return last;
    }
  }

  const nextVerNum = versions.length > 0 ? (versions[versions.length - 1].version + 1) : 1;
  const snapshot = {
    id: `v_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`,
    version: nextVerNum,
    timestamp: new Date().toISOString(),
    source, // 'user_edit' | 'agent_pre' | 'agent_post' | 'rollback' | 'initial'
    summary: summary || source,
    content,
    charCount: content.length,
    lineCount: content.split('\n').length,
  };

  versions.push(snapshot);
  if (versions.length > MAX_VERSIONS) {
    versions = versions.slice(-MAX_VERSIONS);
  }

  fs.writeFileSync(fp, JSON.stringify(versions, null, 2), 'utf-8');
  return snapshot;
}

export function rollbackToVersion(userId, versionId, writeMemCallback) {
  const versions = getVersions(userId);
  const target = versions.find(
    (v) => v.id === versionId || String(v.version) === String(versionId),
  );
  if (!target) {
    throw new Error(`Version ${versionId} not found`);
  }

  // 1. Write the target content to current memory file
  writeMemCallback(userId, target.content);

  // 2. Record rollback as a new version iteration
  const newSnapshot = addSnapshot(
    userId,
    target.content,
    'rollback',
    `Rollback to v${target.version}`,
  );

  return { target, newSnapshot, currentVersions: getVersions(userId) };
}
