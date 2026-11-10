const fs = require('fs');
const path = require('path');

const VAULT_DIR = path.join(__dirname, 'vault');
const INDEX_PATH = path.join(VAULT_DIR, 'index.json');
const EMBEDDINGS_PATH = path.join(VAULT_DIR, 'embeddings.json');
const EVENTS_DIR = path.join(VAULT_DIR, 'events');

const CITY_COORDINATES = {
  san_francisco: { name: '旧金山', latitude: 37.7749, longitude: -122.4194 },
  berkeley: { name: '伯克利', latitude: 37.8715, longitude: -122.2730 },
  shanghai: { name: '上海', latitude: 31.2304, longitude: 121.4737 }
};

const COMMON_HEADERS = {
  'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  'Accept': 'application/json, text/plain, */*',
  'x-luma-client-type': 'luma-web',
  'x-luma-web-url': 'https://luma.com/sf',
  'Referer': 'https://luma.com/',
  'Origin': 'https://luma.com'
};

function parseMmDdYy(str) {
  if (!str || typeof str !== 'string') return null;
  const s = str.trim();
  const match = s.match(/^(\d{1,2})[:\-\/](\d{1,2})[:\-\/](\d{2,4})$/);
  if (match) {
    const month = parseInt(match[1], 10);
    const day = parseInt(match[2], 10);
    let year = parseInt(match[3], 10);
    if (year < 100) year += 2000;
    return `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
  }
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) {
    return s;
  }
  return null;
}

function proseMirrorToMarkdown(node) {
  if (!node) return '';
  if (node.type === 'text') {
    let text = node.text || '';
    if (node.marks) {
      for (const m of node.marks) {
        if (m.type === 'link') text = `[${text}](${m.attrs?.href || ''})`;
        else if (m.type === 'bold') text = `**${text}**`;
        else if (m.type === 'italic') text = `*${text}*`;
        else if (m.type === 'code') text = `\`${text}\``;
      }
    }
    return text;
  }
  if (node.type === 'hard_break') return '\n';
  const children = (node.content || []).map(proseMirrorToMarkdown).join('');
  if (node.type === 'paragraph') return children + '\n\n';
  if (node.type === 'heading') {
    const level = node.attrs?.level || 1;
    return '#'.repeat(level) + ' ' + children + '\n\n';
  }
  if (node.type === 'bullet_list') return (node.content || []).map(li => '- ' + proseMirrorToMarkdown(li).trim()).join('\n') + '\n\n';
  if (node.type === 'ordered_list') return (node.content || []).map((li, idx) => `${idx + 1}. ` + proseMirrorToMarkdown(li).trim()).join('\n') + '\n\n';
  if (node.type === 'list_item') return children.trim();
  if (node.type === 'blockquote') return '> ' + children.trim() + '\n\n';
  return children;
}

function addLineNumbers(text) {
  const lines = text.split('\n');
  const maxLineNumWidth = Math.max(String(lines.length).length, 4);
  return lines.map((line, idx) => {
    const lineNum = String(idx + 1).padStart(maxLineNumWidth, ' ');
    return `${lineNum}|${line}`;
  }).join('\n');
}

// Cosine similarity
function cosineSimilarity(a, b) {
  if (!a || !b || a.length !== b.length) return 0;
  let dot = 0, normA = 0, normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  if (normA === 0 || normB === 0) return 0;
  return dot / (Math.sqrt(normA) * Math.sqrt(normB));
}

// In-memory cache
let vaultIndex = { updated_at: 0, nodes: {} };
let vaultEmbeddings = {};
let embedder = null;
let isSyncing = false;
let syncStats = {
  status: 'idle',
  lastSyncTime: 0,
  totalEvents: 0,
  lastNewEvents: 0,
  error: null
};

// Manual sync task state
let currentSyncTask = {
  id: null,
  status: 'idle', // 'idle' | 'running' | 'completed' | 'error'
  startTime: null,
  endTime: null,
  startDateStr: null,
  endDateStr: null,
  locations: [],
  currentCity: '',
  currentPage: 0,
  totalScanned: 0,
  newAdded: 0,
  skippedCount: 0,
  progress: 0.0,
  message: '尚未发起同步任务',
  error: null
};

async function getEmbedder() {
  if (!embedder) {
    const { pipeline } = await import('@xenova/transformers');
    embedder = await pipeline('feature-extraction', 'Xenova/all-MiniLM-L6-v2');
  }
  return embedder;
}

function initVaultStorage() {
  if (!fs.existsSync(VAULT_DIR)) {
    fs.mkdirSync(VAULT_DIR, { recursive: true });
  }
  if (!fs.existsSync(EVENTS_DIR)) {
    fs.mkdirSync(EVENTS_DIR, { recursive: true });
  }
  if (fs.existsSync(INDEX_PATH)) {
    try {
      vaultIndex = JSON.parse(fs.readFileSync(INDEX_PATH, 'utf-8'));
    } catch (e) {
      vaultIndex = { updated_at: 0, nodes: {} };
    }
  }
  if (fs.existsSync(EMBEDDINGS_PATH)) {
    try {
      vaultEmbeddings = JSON.parse(fs.readFileSync(EMBEDDINGS_PATH, 'utf-8'));
    } catch (e) {
      vaultEmbeddings = {};
    }
  }
  syncStats.totalEvents = Object.keys(vaultIndex.nodes || {}).length;
  syncStats.lastSyncTime = vaultIndex.updated_at || 0;
}

function saveVaultStorage() {
  vaultIndex.updated_at = Date.now();
  fs.writeFileSync(INDEX_PATH, JSON.stringify(vaultIndex, null, 2), 'utf-8');
  fs.writeFileSync(EMBEDDINGS_PATH, JSON.stringify(vaultEmbeddings), 'utf-8');
  syncStats.totalEvents = Object.keys(vaultIndex.nodes || {}).length;
  syncStats.lastSyncTime = vaultIndex.updated_at;
}

async function fetchFromLuma(slug, cursor, lat, lon, limit = 50) {
  const targetUrl = new URL('https://api.luma.com/discover/get-paginated-events');
  targetUrl.searchParams.set('latitude', String(lat));
  targetUrl.searchParams.set('longitude', String(lon));
  targetUrl.searchParams.set('pagination_limit', String(limit));
  if (slug) targetUrl.searchParams.set('slug', slug);
  if (cursor) targetUrl.searchParams.set('pagination_cursor', cursor);

  const response = await fetch(targetUrl.toString(), { headers: COMMON_HEADERS });
  if (!response.ok) {
    return { entries: [], has_more: false, next_cursor: null };
  }
  return await response.json();
}

async function fetchEventDetail(eventApiId) {
  if (!eventApiId) return null;
  const targetUrl = `https://api.luma.com/event/get?event_api_id=${encodeURIComponent(eventApiId)}`;
  try {
    const response = await fetch(targetUrl, { headers: COMMON_HEADERS });
    if (!response.ok) return null;
    return await response.json();
  } catch {
    return null;
  }
}

function formatSingleEventMarkdown(node, displayIndex = null) {
  const prefix = displayIndex ? `## [${displayIndex}] ` : `## `;
  let md = `${prefix}${node.title || '未命名活动'}\n\n`;
  md += `- **活动链接**: ${node.url || ''}\n`;
  md += `- **活动 ID**: ${node.api_id || node.id || ''}\n`;
  md += `- **起止时间**: ${node.start_at || '未定'} ~ ${node.end_at || '未定'} (${node.timezone || ''})\n`;
  md += `- **详细地点**: ${node.location_address || '地点未标明'}\n`;
  md += `- **费用说明**: ${node.ticket_summary || '未标明'}\n`;
  md += `- **申请批准机制**: ${node.require_approval ? '需要主办方申请批准 / 审核' : '无需申请批准，可直接参加'}\n`;
  md += `- **主办方**: ${node.hosts || '未标明'}\n`;
  md += `- **社区日历**: ${node.calendar || '无关联日历'}\n\n`;
  md += `### 活动完整说明\n\n`;
  md += node.description && node.description.trim().length > 0
    ? `${node.description.trim()}\n\n`
    : `主办方未提供图文正文说明。\n\n`;
  md += `---\n\n`;
  return md;
}

// Background hourly sync engine (default 3 months)
async function syncLumaVault({ force = false } = {}) {
  if (isSyncing) {
    return { syncing: true, message: 'Sync already in progress' };
  }
  isSyncing = true;
  syncStats.status = 'syncing';
  syncStats.error = null;

  const now = Date.now();
  const THREE_MONTHS_MS = 90 * 24 * 60 * 60 * 1000;
  const cutoffTime = now + THREE_MONTHS_MS;
  let newEventsCount = 0;

  try {
    const pipelineEmbedder = await getEmbedder();

    for (const [cityKey, coords] of Object.entries(CITY_COORDINATES)) {
      let cursor = null;
      let pageNum = 0;
      let reachedCutoff = false;

      while (!reachedCutoff && pageNum < 40) {
        pageNum++;
        let res;
        try {
          res = await fetchFromLuma(null, cursor, coords.latitude, coords.longitude, 50);
        } catch (fetchErr) {
          console.error(`[Luma Vault Sync] Error fetching page ${pageNum} for ${cityKey}:`, fetchErr.message);
          break;
        }

        const entries = res.entries || [];
        if (entries.length === 0) break;

        const detailTasks = [];
        for (const item of entries) {
          const ev = item.event || {};
          const apiId = ev.api_id;
          if (!apiId) continue;
          const nodeId = `luma_${apiId}`;

          if (!force && vaultIndex.nodes[nodeId] && vaultEmbeddings[nodeId]) {
            vaultIndex.nodes[nodeId].last_seen = now;
            continue;
          }

          detailTasks.push((async () => {
            try {
              const dt = await fetchEventDetail(apiId);
              const descMd = dt ? proseMirrorToMarkdown(dt.description_mirror) : '';
              const geo = ev.geo_address_info || {};
              const fullAddr = geo.full_address || geo.address || geo.city || '地点未标明';
              const isFree = item.ticket_info?.is_free ?? true;
              const requireApproval = item.ticket_info?.require_approval ?? false;
              const ticketTypes = dt?.ticket_types || [];
              let ticketSummary = isFree ? '免费' : '付费';
              if (ticketTypes.length > 0) {
                ticketSummary = ticketTypes.map(t => {
                  const tName = t.name || '标准票';
                  const tFree = t.type === 'free' || t.cents === null;
                  const price = tFree ? '免费' : `$${(t.cents / 100).toFixed(2)}`;
                  return `${tName} (${price})`;
                }).join(', ');
              }

              const hosts = (item.hosts || []).map(h => h.name).filter(Boolean).join(', ') || '未标明';
              const calendarName = item.calendar?.name || '无关联日历';

              const catKeywords = [];
              const combinedText = `${ev.name || ''} ${descMd} ${calendarName}`.toLowerCase();
              if (combinedText.includes('ai') || combinedText.includes('llm') || combinedText.includes('gpt') || combinedText.includes('model') || combinedText.includes('agent')) catKeywords.push('ai');
              if (combinedText.includes('crypto') || combinedText.includes('web3') || combinedText.includes('blockchain') || combinedText.includes('eth') || combinedText.includes('btc') || combinedText.includes('token')) catKeywords.push('crypto');
              if (combinedText.includes('tech') || combinedText.includes('software') || combinedText.includes('code') || combinedText.includes('developer') || combinedText.includes('hackathon') || catKeywords.length > 0) catKeywords.push('tech');

              const node = {
                id: nodeId,
                api_id: apiId,
                title: ev.name || '未命名活动',
                url: `https://luma.com/${ev.url || ''}`,
                start_at: ev.start_at || '',
                end_at: ev.end_at || '',
                timezone: ev.timezone || '',
                city: cityKey,
                cityName: coords.name,
                location_address: fullAddr,
                ticket_summary: ticketSummary,
                is_free: isFree,
                require_approval: requireApproval,
                hosts: hosts,
                calendar: calendarName,
                description: descMd,
                categories: catKeywords,
                source: 'Luma',
                source_type: 'public',
                created_at: new Date().toISOString(),
                last_seen: now
              };

              const embedText = `${node.title} | ${node.cityName} ${node.location_address} | 主办: ${node.hosts} | 日历: ${node.calendar} | 类别: ${node.categories.join(' ')} | ${node.description.slice(0, 1200)}`;
              const output = await pipelineEmbedder(embedText, { pooling: 'mean', normalize: true });
              const embedding = Array.from(output.data);

              vaultIndex.nodes[nodeId] = node;
              vaultEmbeddings[nodeId] = embedding;

              const nodeMd = formatSingleEventMarkdown(node);
              fs.writeFileSync(path.join(EVENTS_DIR, `${nodeId}.md`), nodeMd, 'utf-8');
              newEventsCount++;
            } catch (err) {
              console.error(`[Luma Vault Sync] Error processing event ${apiId}:`, err.message);
            }
          })());
        }

        if (detailTasks.length > 0) {
          await Promise.all(detailTasks);
        }

        const lastEntry = entries[entries.length - 1];
        if (lastEntry?.event?.start_at) {
          const lastTime = new Date(lastEntry.event.start_at).getTime();
          if (lastTime >= cutoffTime) {
            reachedCutoff = true;
            break;
          }
        }

        if (!res.has_more || !res.next_cursor) {
          break;
        }
        cursor = res.next_cursor;
        await new Promise(r => setTimeout(r, 100));
      }
    }

    // Prune past events (ended more than 24h ago)
    const yesterday = now - 24 * 60 * 60 * 1000;
    for (const [id, node] of Object.entries(vaultIndex.nodes)) {
      if (node.end_at) {
        const endTime = new Date(node.end_at).getTime();
        if (endTime < yesterday) {
          delete vaultIndex.nodes[id];
          delete vaultEmbeddings[id];
          const mdFile = path.join(EVENTS_DIR, `${id}.md`);
          if (fs.existsSync(mdFile)) {
            try { fs.unlinkSync(mdFile); } catch (e) {}
          }
        }
      }
    }

    saveVaultStorage();
    syncStats.status = 'idle';
    syncStats.lastNewEvents = newEventsCount;
    return { success: true, new_events: newEventsCount, total_events: Object.keys(vaultIndex.nodes).length };
  } catch (error) {
    console.error('[Luma Vault Sync] Critical sync error:', error);
    syncStats.status = 'error';
    syncStats.error = error.message;
    return { success: false, error: error.message };
  } finally {
    isSyncing = false;
  }
}

// Manual sync task engine with live progress, date range constraint, and skipping cached items
function getManualSyncTaskStatus() {
  return {
    ...currentSyncTask,
    vaultTotal: Object.keys(vaultIndex.nodes || {}).length,
    lastSyncTime: vaultIndex.updated_at || 0
  };
}

async function startManualSyncTask({ startDateStr, endDateStr, locations = [] }) {
  if (!startDateStr || !endDateStr) {
    throw new Error('必须指定时间段（开始时间与结束时间）');
  }

  if (currentSyncTask.status === 'running') {
    return { running: true, message: '已有同步任务正在进行中', task: getManualSyncTaskStatus() };
  }

  const selectedLocations = (Array.isArray(locations) ? locations : [locations])
    .map(l => String(l).toLowerCase().trim())
    .filter(l => CITY_COORDINATES[l]);
  const finalLocations = selectedLocations.length > 0 ? selectedLocations : Object.keys(CITY_COORDINATES);

  const taskId = `sync_${Date.now()}`;
  currentSyncTask = {
    id: taskId,
    status: 'running',
    startTime: Date.now(),
    endTime: null,
    startDateStr,
    endDateStr,
    locations: finalLocations,
    currentCity: '',
    currentPage: 0,
    totalScanned: 0,
    newAdded: 0,
    skippedCount: 0,
    progress: 0.05,
    message: '正在准备同步...',
    error: null
  };

  // Launch background execution
  (async () => {
    try {
      const pipelineEmbedder = await getEmbedder();
      const minTime = new Date(`${startDateStr}T00:00:00Z`).getTime();
      const maxTime = new Date(`${endDateStr}T23:59:59.999Z`).getTime();
      const totalCities = finalLocations.length;

      for (let cityIdx = 0; cityIdx < totalCities; cityIdx++) {
        const cityKey = finalLocations[cityIdx];
        const coords = CITY_COORDINATES[cityKey];
        if (!coords) continue;

        currentSyncTask.currentCity = coords.name;
        currentSyncTask.message = `正在扫描 ${coords.name} 活动...`;

        const initialCursorObj = {
          sv: `${startDateStr} 00:00:00+00`,
          fb: 'evt-000000000000000'
        };
        let cursor = Buffer.from(JSON.stringify(initialCursorObj)).toString('base64');
        let pageNum = 0;
        let reachedCutoff = false;

        while (!reachedCutoff && pageNum < 50) {
          pageNum++;
          currentSyncTask.currentPage = pageNum;
          currentSyncTask.message = `正在扫描 ${coords.name} 第 ${pageNum} 页活动...`;

          let res;
          try {
            res = await fetchFromLuma(null, cursor, coords.latitude, coords.longitude, 50);
          } catch (fetchErr) {
            console.error(`[Manual Sync Task] Page fetch error for ${cityKey} page ${pageNum}:`, fetchErr.message);
            break;
          }

          const entries = res.entries || [];
          if (entries.length === 0) break;

          const toFetchDetails = [];
          for (const item of entries) {
            const ev = item.event || {};
            const apiId = ev.api_id;
            if (!apiId) continue;

            const itemTime = new Date(ev.start_at).getTime();
            if (itemTime > maxTime) {
              reachedCutoff = true;
              break;
            }
            if (itemTime < minTime) {
              continue;
            }

            const nodeId = `luma_${apiId}`;
            currentSyncTask.totalScanned++;

            // 跳过已经存进去的
            if (vaultIndex.nodes[nodeId] && vaultEmbeddings[nodeId]) {
              vaultIndex.nodes[nodeId].last_seen = Date.now();
              currentSyncTask.skippedCount++;
              continue;
            }

            toFetchDetails.push({ item, ev, apiId, nodeId });
          }

          // Fetch details for new events
          for (const { item, ev, apiId, nodeId } of toFetchDetails) {
            try {
              const dt = await fetchEventDetail(apiId);
              const descMd = dt ? proseMirrorToMarkdown(dt.description_mirror) : '';
              const geo = ev.geo_address_info || {};
              const fullAddr = geo.full_address || geo.address || geo.city || '地点未标明';
              const isFree = item.ticket_info?.is_free ?? true;
              const requireApproval = item.ticket_info?.require_approval ?? false;
              const ticketTypes = dt?.ticket_types || [];
              let ticketSummary = isFree ? '免费' : '付费';
              if (ticketTypes.length > 0) {
                ticketSummary = ticketTypes.map(t => {
                  const tName = t.name || '标准票';
                  const tFree = t.type === 'free' || t.cents === null;
                  const price = tFree ? '免费' : `$${(t.cents / 100).toFixed(2)}`;
                  return `${tName} (${price})`;
                }).join(', ');
              }

              const hosts = (item.hosts || []).map(h => h.name).filter(Boolean).join(', ') || '未标明';
              const calendarName = item.calendar?.name || '无关联日历';

              const catKeywords = [];
              const combinedText = `${ev.name || ''} ${descMd} ${calendarName}`.toLowerCase();
              if (combinedText.includes('ai') || combinedText.includes('llm') || combinedText.includes('gpt') || combinedText.includes('model') || combinedText.includes('agent')) catKeywords.push('ai');
              if (combinedText.includes('crypto') || combinedText.includes('web3') || combinedText.includes('blockchain') || combinedText.includes('eth') || combinedText.includes('btc') || combinedText.includes('token')) catKeywords.push('crypto');
              if (combinedText.includes('tech') || combinedText.includes('software') || combinedText.includes('code') || combinedText.includes('developer') || combinedText.includes('hackathon') || catKeywords.length > 0) catKeywords.push('tech');

              const node = {
                id: nodeId,
                api_id: apiId,
                title: ev.name || '未命名活动',
                url: `https://luma.com/${ev.url || ''}`,
                start_at: ev.start_at || '',
                end_at: ev.end_at || '',
                timezone: ev.timezone || '',
                city: cityKey,
                cityName: coords.name,
                location_address: fullAddr,
                ticket_summary: ticketSummary,
                is_free: isFree,
                require_approval: requireApproval,
                hosts: hosts,
                calendar: calendarName,
                description: descMd,
                categories: catKeywords,
                source: 'Luma',
                source_type: 'public',
                created_at: new Date().toISOString(),
                last_seen: Date.now()
              };

              const embedText = `${node.title} | ${node.cityName} ${node.location_address} | 主办: ${node.hosts} | 日历: ${node.calendar} | 类别: ${node.categories.join(' ')} | ${node.description.slice(0, 1200)}`;
              const output = await pipelineEmbedder(embedText, { pooling: 'mean', normalize: true });
              const embedding = Array.from(output.data);

              vaultIndex.nodes[nodeId] = node;
              vaultEmbeddings[nodeId] = embedding;

              const nodeMd = formatSingleEventMarkdown(node);
              fs.writeFileSync(path.join(EVENTS_DIR, `${nodeId}.md`), nodeMd, 'utf-8');
              currentSyncTask.newAdded++;
            } catch (err) {
              console.error(`[Manual Sync Task] Error processing event ${apiId}:`, err.message);
            }
          }

          // Calculate estimated progress
          const lastEntry = entries[entries.length - 1];
          let cityProgress = 0.5;
          if (lastEntry?.event?.start_at) {
            const lastTime = new Date(lastEntry.event.start_at).getTime();
            const timeSpan = maxTime - minTime;
            if (timeSpan > 0) {
              cityProgress = Math.min(Math.max((lastTime - minTime) / timeSpan, 0), 1);
            }
          }
          const overallProgress = (cityIdx + cityProgress) / totalCities;
          currentSyncTask.progress = Math.min(Math.max(Number(overallProgress.toFixed(2)), 0.05), 0.98);
          currentSyncTask.message = `正在扫描 ${coords.name}（第 ${pageNum} 页）：已扫描 ${currentSyncTask.totalScanned} 个，新增入库 ${currentSyncTask.newAdded} 个，跳过已存在 ${currentSyncTask.skippedCount} 个`;

          if (reachedCutoff || !res.has_more || !res.next_cursor) {
            break;
          }
          cursor = res.next_cursor;
          await new Promise(r => setTimeout(r, 100));
        }
      }

      saveVaultStorage();
      currentSyncTask.status = 'completed';
      currentSyncTask.progress = 1.0;
      currentSyncTask.endTime = Date.now();
      currentSyncTask.message = `同步完成。指定时间段内共扫描 ${currentSyncTask.totalScanned} 个活动，新增入库 ${currentSyncTask.newAdded} 个，跳过已存在 ${currentSyncTask.skippedCount} 个活动。`;
    } catch (taskErr) {
      console.error('[Manual Sync Task] Error:', taskErr);
      currentSyncTask.status = 'error';
      currentSyncTask.error = taskErr.message;
      currentSyncTask.message = `同步失败：${taskErr.message}`;
    }
  })();

  return { success: true, taskId, task: getManualSyncTaskStatus() };
}

// Semantic search over Luma public vault
async function searchVaultCore({
  searchkeys,
  locations = [],
  categories = [],
  startDateStr = null,
  endDateStr = null,
  limit = 5
}) {
  const query = (searchkeys || '').trim();
  if (!query) {
    return null;
  }

  const pipelineEmbedder = await getEmbedder();
  const output = await pipelineEmbedder(query, { pooling: 'mean', normalize: true });
  const queryEmbedding = Array.from(output.data);

  const selectedLocations = (Array.isArray(locations) ? locations : [locations])
    .map(l => String(l).toLowerCase().trim())
    .filter(l => CITY_COORDINATES[l]);

  const selectedCategories = (Array.isArray(categories) ? categories : [categories])
    .map(c => String(c).toLowerCase().trim())
    .filter(Boolean);

  let minTime = null;
  let maxTime = null;
  if (startDateStr) minTime = new Date(`${startDateStr}T00:00:00Z`).getTime();
  if (endDateStr) maxTime = new Date(`${endDateStr}T23:59:59.999Z`).getTime();

  const queryTerms = query.toLowerCase().split(/\s+/).filter(t => t.length > 1);

  const candidates = [];
  const now = Date.now();

  for (const [nodeId, node] of Object.entries(vaultIndex.nodes)) {
    if (node.end_at && new Date(node.end_at).getTime() < now) {
      continue;
    }

    if (selectedLocations.length > 0 && !selectedLocations.includes(node.city)) {
      continue;
    }

    if (selectedCategories.length > 0) {
      const hasCategory = selectedCategories.some(cat => 
        (node.categories || []).includes(cat) ||
        (node.title || '').toLowerCase().includes(cat) ||
        (node.description || '').toLowerCase().includes(cat)
      );
      if (!hasCategory) continue;
    }

    if (node.start_at) {
      const itemTime = new Date(node.start_at).getTime();
      if (minTime !== null && itemTime < minTime) continue;
      if (maxTime !== null && itemTime > maxTime) continue;
    }

    const embedding = vaultEmbeddings[nodeId];
    if (!embedding) continue;
    const sim = cosineSimilarity(queryEmbedding, embedding);

    let lexicalScore = 0;
    const nodeText = `${node.title || ''} ${node.description || ''} ${node.hosts || ''} ${node.location_address || ''} ${(node.categories || []).join(' ')}`.toLowerCase();
    for (const term of queryTerms) {
      if ((node.title || '').toLowerCase().includes(term)) lexicalScore += 0.5;
      else if (nodeText.includes(term)) lexicalScore += 0.2;
    }

    const finalScore = sim * 0.7 + Math.min(lexicalScore, 1.0) * 0.3;

    candidates.push({
      node,
      similarity: sim,
      score: finalScore
    });
  }

  candidates.sort((a, b) => b.score - a.score);
  const topMatches = candidates.slice(0, Math.max(limit, 1));

  let rawMd = `# Luma 活动语义检索结果 (关键词: "${query}")\n\n`;
  rawMd += `- **检索语义关键词**: ${query}\n`;
  rawMd += `- **搜索范围**: Luma 公共活动 Vault (未来 3 个月内活动)\n`;
  rawMd += `- **筛选地点**: ${selectedLocations.length > 0 ? selectedLocations.map(l => CITY_COORDINATES[l]?.name).join(' / ') : '全部地点'}\n`;
  rawMd += `- **筛选类别**: ${selectedCategories.length > 0 ? selectedCategories.join(', ') : '全部类别'}\n`;
  if (startDateStr || endDateStr) {
    rawMd += `- **时间范围**: ${startDateStr || '不限'} 至 ${endDateStr || '不限'}\n`;
  }
  rawMd += `- **命中活动数**: 本次检索返回 top ${topMatches.length} 个最匹配活动\n`;
  rawMd += `- **检索模式**: AutoRAG 语义向量检索 (Xenova/all-MiniLM-L6-v2 + BM25)\n\n`;
  rawMd += `---\n\n`;

  topMatches.forEach((match, idx) => {
    rawMd += formatSingleEventMarkdown(match.node, idx + 1);
  });

  const numberedContent = addLineNumbers(rawMd);
  const estimatedTokens = Math.round(rawMd.length / 3.5);

  return {
    is_semantic_search: true,
    query: query,
    title: `Luma 活动语义检索: "${query}" (命中 ${topMatches.length} 个活动)`,
    url: 'https://luma.com',
    total_events: topMatches.length,
    estimated_tokens: estimatedTokens,
    char_count: rawMd.length,
    raw_content: rawMd,
    content: numberedContent,
    matches: topMatches.map(m => ({
      id: m.node.id,
      title: m.node.title,
      url: m.node.url,
      start_at: m.node.start_at,
      location: m.node.location_address,
      city: m.node.cityName,
      similarity: Number(m.similarity.toFixed(4)),
      score: Number(m.score.toFixed(4))
    }))
  };
}

// Initial load
initVaultStorage();

module.exports = {
  VAULT_DIR,
  CITY_COORDINATES,
  COMMON_HEADERS,
  parseMmDdYy,
  proseMirrorToMarkdown,
  addLineNumbers,
  fetchFromLuma,
  fetchEventDetail,
  formatSingleEventMarkdown,
  syncLumaVault,
  startManualSyncTask,
  getManualSyncTaskStatus,
  searchVaultCore,
  getVaultStatus: () => ({
    ...syncStats,
    isSyncing,
    totalEvents: Object.keys(vaultIndex.nodes || {}).length,
    lastSyncTime: vaultIndex.updated_at || syncStats.lastSyncTime
  })
};
