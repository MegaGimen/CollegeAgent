const express = require('express');
const cors = require('cors');
const {
  CITY_COORDINATES,
  COMMON_HEADERS,
  parseMmDdYy,
  proseMirrorToMarkdown,
  addLineNumbers,
  fetchFromLuma,
  fetchEventDetail,
  syncLumaVault,
  startManualSyncTask,
  getManualSyncTaskStatus,
  searchVaultCore,
  getVaultStatus
} = require('./vault_engine.js');

const app = express();
const PORT = process.env.PORT || 8004;

app.use(cors());
app.use(express.json({ limit: '10mb' }));

// Unified query core (Live Luma API)
async function queryEventsCore({
  locations = ['san_francisco'],
  categories = [],
  startDateStr = null, // YYYY-MM-DD
  endDateStr = null,   // YYYY-MM-DD
  page = 1,
  limit = 50,
  cursor = null,
  query = null
}) {
  const selectedLocations = (Array.isArray(locations) ? locations : [locations])
    .map(l => String(l).toLowerCase().trim())
    .filter(l => CITY_COORDINATES[l]);
  if (selectedLocations.length === 0) selectedLocations.push('san_francisco');

  const selectedCategories = (Array.isArray(categories) ? categories : [categories])
    .map(c => String(c).toLowerCase().trim())
    .filter(Boolean);

  let effectiveCursor = cursor || null;
  if (!effectiveCursor && startDateStr) {
    const initialCursorObj = {
      sv: `${startDateStr} 00:00:00+00`,
      fb: 'evt-000000000000000'
    };
    effectiveCursor = Buffer.from(JSON.stringify(initialCursorObj)).toString('base64');
  }

  let currentPage = 1;
  let hasMore = false;
  let nextCursor = null;
  let pageEntries = [];

  const targetPage = Math.max(parseInt(page, 10) || 1, 1);

  const fetchSinglePage = async (currentCursor) => {
    const tasks = [];
    for (const loc of selectedLocations) {
      const coord = CITY_COORDINATES[loc];
      if (selectedCategories.length === 0) {
        tasks.push(fetchFromLuma(null, currentCursor, coord.latitude, coord.longitude, limit));
      } else {
        for (const cat of selectedCategories) {
          tasks.push(fetchFromLuma(cat, currentCursor, coord.latitude, coord.longitude, limit));
        }
      }
    }

    const batchResults = await Promise.all(tasks);
    let batchHasMore = false;
    const seen = new Set();
    const merged = [];

    for (const r of batchResults) {
      if (r.has_more) batchHasMore = true;
      for (const item of r.entries || []) {
        const id = item.event?.api_id || item.api_id;
        if (id && !seen.has(id)) {
          seen.add(id);
          merged.push(item);
        }
      }
    }

    merged.sort((a, b) => new Date(a.event.start_at) - new Date(b.event.start_at));

    let batchNextCursor = null;
    if (merged.length > 0) {
      const lastItem = merged[Math.min(merged.length - 1, limit - 1)];
      const lastIso = lastItem.event.start_at;
      const lastId = lastItem.event.api_id;
      const nextCursorObj = {
        sv: lastIso.replace('T', ' ').replace('Z', '+00'),
        fb: lastId
      };
      batchNextCursor = Buffer.from(JSON.stringify(nextCursorObj)).toString('base64');
    }

    return { entries: merged.slice(0, limit), has_more: batchHasMore, next_cursor: batchNextCursor };
  };

  if (effectiveCursor) {
    const res = await fetchSinglePage(effectiveCursor);
    pageEntries = res.entries;
    hasMore = res.has_more;
    nextCursor = res.next_cursor;
  } else {
    let curCursor = null;
    while (currentPage <= targetPage) {
      const res = await fetchSinglePage(curCursor);
      pageEntries = res.entries;
      hasMore = res.has_more;
      nextCursor = res.next_cursor;
      if (currentPage === targetPage || !hasMore || !nextCursor) {
        break;
      }
      curCursor = nextCursor;
      currentPage++;
    }
  }

  // Filter by date range
  let minTime = null;
  let maxTime = null;
  if (startDateStr) minTime = new Date(`${startDateStr}T00:00:00Z`).getTime();
  if (endDateStr) maxTime = new Date(`${endDateStr}T23:59:59.999Z`).getTime();

  if (minTime !== null || maxTime !== null) {
    pageEntries = pageEntries.filter(item => {
      const itemTime = new Date(item.event.start_at).getTime();
      if (minTime !== null && itemTime < minTime) return false;
      if (maxTime !== null && itemTime > maxTime) return false;
      return true;
    });

    if (maxTime !== null) {
      const anyExceeded = pageEntries.some(item => new Date(item.event.start_at).getTime() > maxTime);
      if (anyExceeded) {
        hasMore = false;
        nextCursor = null;
      }
    }
  }

  return {
    locations: selectedLocations,
    locationNames: selectedLocations.map(l => CITY_COORDINATES[l].name),
    categories: selectedCategories,
    page: targetPage,
    entries: pageEntries,
    has_more: hasMore,
    next_cursor: nextCursor
  };
}

// Dump page markdown function (Live API)
async function dumpPageMarkdownCore(params) {
  const queryRes = await queryEventsCore(params);
  const entries = queryRes.entries;

  const detailTasks = entries.map(e => fetchEventDetail(e.event?.api_id));
  const details = await Promise.all(detailTasks);

  const locLabels = queryRes.locationNames.join(' / ');
  const catLabels = queryRes.categories.length > 0 ? queryRes.categories.join(', ') : '全部类别';
  const dateRangeLabel = (params.rawStartDate || params.startDateStr) && (params.rawEndDate || params.endDateStr)
    ? `${params.rawStartDate || params.startDateStr} 至 ${params.rawEndDate || params.endDateStr}`
    : ((params.rawStartDate || params.startDateStr)
        ? `${params.rawStartDate || params.startDateStr} 起`
        : ((params.rawEndDate || params.endDateStr) ? `截至 ${params.rawEndDate || params.endDateStr}` : '不限时间'));

  let rawMd = `# Luma 活动列表完整 Dump\n\n`;
  rawMd += `- **查询地点**: ${locLabels}\n`;
  rawMd += `- **活动类别**: ${catLabels}\n`;
  rawMd += `- **时间范围**: ${dateRangeLabel}\n`;
  rawMd += `- **当前页码**: 第 ${queryRes.page} 页 (本页共 ${entries.length} 个活动)\n`;
  rawMd += `- **是否还有下页**: ${queryRes.has_more ? '是' : '否'}\n`;
  rawMd += `- **数据来源**: Luma 实时 API 请求\n\n`;
  rawMd += `---\n\n`;

  entries.forEach((item, idx) => {
    const ev = item.event || {};
    const dt = details[idx] || {};
    const descMd = proseMirrorToMarkdown(dt.description_mirror).trim();
    const geo = ev.geo_address_info || {};
    const fullAddr = geo.full_address || geo.address || geo.city || '地点未标明';
    const isFree = item.ticket_info?.is_free ?? true;
    const requireApproval = item.ticket_info?.require_approval ?? false;
    const ticketTypes = dt.ticket_types || [];
    let ticketSummary = isFree ? '免费' : '付费';
    if (ticketTypes.length > 0) {
      ticketSummary = ticketTypes.map(t => {
        const tName = t.name || '标准票';
        const tFree = t.type === 'free' || t.cents === null;
        const price = tFree ? '免费' : `$${(t.cents / 100).toFixed(2)}`;
        return `${tName} (${price})`;
      }).join(', ');
    }

    const hosts = item.hosts || [];
    const hostNames = hosts.map(h => h.name).filter(Boolean).join(', ') || '未标明';
    const calendarName = item.calendar?.name || '无关联日历';

    rawMd += `## [${idx + 1}] ${ev.name || '未命名活动'}\n\n`;
    rawMd += `- **活动链接**: https://luma.com/${ev.url || ''}\n`;
    rawMd += `- **活动 ID**: ${ev.api_id || item.api_id || ''}\n`;
    rawMd += `- **起止时间**: ${ev.start_at || '未定'} ~ ${ev.end_at || '未定'} (${ev.timezone || ''})\n`;
    rawMd += `- **详细地点**: ${fullAddr}\n`;
    rawMd += `- **费用说明**: ${ticketSummary}\n`;
    rawMd += `- **申请批准机制**: ${requireApproval ? '需要主办方申请批准 / 审核' : '无需申请批准，可直接参加'}\n`;
    rawMd += `- **主办方**: ${hostNames}\n`;
    rawMd += `- **社区日历**: ${calendarName}\n\n`;
    rawMd += `### 活动完整说明\n\n`;
    rawMd += descMd && descMd.length > 0 ? `${descMd}\n\n` : `主办方未提供图文正文说明。\n\n`;
    rawMd += `---\n\n`;
  });

  const numberedContent = addLineNumbers(rawMd);
  const estimatedTokens = Math.round(rawMd.length / 3.5);

  return {
    is_semantic_search: false,
    title: `Luma 活动列表 Dump (${locLabels} | 第 ${queryRes.page} 页 | 共 ${entries.length} 个活动)`,
    url: 'https://luma.com',
    page: queryRes.page,
    locations: queryRes.locations,
    location_names: queryRes.locationNames,
    categories: queryRes.categories,
    start_date: params.rawStartDate || params.startDateStr || null,
    end_date: params.rawEndDate || params.endDateStr || null,
    total_events: entries.length,
    has_more: queryRes.has_more,
    next_cursor: queryRes.next_cursor,
    content: numberedContent,
    raw_content: rawMd,
    char_count: rawMd.length,
    estimated_tokens: estimatedTokens
  };
}

// Health check
app.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    service: 'luma-service',
    port: PORT,
    vault: getVaultStatus()
  });
});

// Supported cities
app.get('/api/cities', (req, res) => {
  res.json(CITY_COORDINATES);
});

// Vault status
app.get('/api/vault/status', (req, res) => {
  res.json(getVaultStatus());
});

// Trigger Vault Sync (Hourly/Auto)
app.post('/api/vault/sync', async (req, res) => {
  const force = req.body?.force === true;
  syncLumaVault({ force }).catch(console.error);
  res.json({ success: true, message: 'Luma vault sync triggered in background' });
});

// Manual Sync Task: Asynchronously crawl events for a specified date range and store into vault
app.post('/api/vault/sync-task', async (req, res) => {
  try {
    const { start_date, end_date, locations } = req.body || {};
    const startDateStr = parseMmDdYy(start_date);
    const endDateStr = parseMmDdYy(end_date);

    if (!startDateStr || !endDateStr) {
      return res.status(400).json({ error: '必须指定时间段（开始时间与结束时间）' });
    }

    const taskResult = await startManualSyncTask({
      startDateStr,
      endDateStr,
      locations
    });

    res.json(taskResult);
  } catch (err) {
    console.error('Error starting manual sync task:', err);
    res.status(500).json({ error: err.message });
  }
});

// Get manual sync task status & progress
app.get('/api/vault/sync-task', (req, res) => {
  res.json(getManualSyncTaskStatus());
});

// Vault semantic search endpoint
app.post('/api/vault/search', async (req, res) => {
  try {
    const {
      searchkeys,
      query,
      locations,
      categories,
      start_date,
      end_date,
      limit = 5
    } = req.body;

    const startDateStr = parseMmDdYy(start_date);
    const endDateStr = parseMmDdYy(end_date);

    const searchResult = await searchVaultCore({
      searchkeys: searchkeys || query,
      locations,
      categories,
      startDateStr,
      endDateStr,
      limit: parseInt(limit, 10) || 5
    });

    if (!searchResult) {
      return res.status(400).json({ error: 'searchkeys or query is required for semantic search' });
    }
    res.json(searchResult);
  } catch (err) {
    console.error('Error in /api/vault/search:', err);
    res.status(500).json({ error: err.message });
  }
});

// GET & POST /api/dump-markdown
const handleDumpMarkdown = async (req, res) => {
  try {
    const params = req.method === 'POST' ? req.body : req.query;
    const {
      searchkeys,
      query,
      locations = 'san_francisco',
      city,
      categories,
      start_date,
      end_date,
      page = 1,
      pagination_cursor,
      limit = 5
    } = params;

    let locList = [];
    if (locations) {
      locList = Array.isArray(locations) ? locations : String(locations).split(',').map(s => s.trim()).filter(Boolean);
    } else if (city) {
      locList = [city];
    } else {
      locList = ['san_francisco'];
    }

    let catList = [];
    if (categories) {
      catList = Array.isArray(categories) ? categories : String(categories).split(',').map(s => s.trim()).filter(Boolean);
    }

    const startDateStr = parseMmDdYy(start_date);
    const endDateStr = parseMmDdYy(end_date);

    // DUAL MODE DISPATCH:
    // If searchkeys is provided -> Semantic search on Vault
    // If searchkeys is omitted -> Standard live API pagination request
    const effectiveSearchKeys = (searchkeys || query || '').trim();
    if (effectiveSearchKeys) {
      const searchResult = await searchVaultCore({
        searchkeys: effectiveSearchKeys,
        locations: locList,
        categories: catList,
        startDateStr,
        endDateStr,
        limit: parseInt(limit, 10) || 5
      });
      return res.json(searchResult);
    }

    // Normal live network request (NOT vault)
    const dumpResult = await dumpPageMarkdownCore({
      locations: locList,
      categories: catList,
      rawStartDate: start_date,
      rawEndDate: end_date,
      startDateStr,
      endDateStr,
      page: parseInt(page, 10) || 1,
      cursor: pagination_cursor || null
    });

    res.json(dumpResult);
  } catch (err) {
    console.error('Error in /api/dump-markdown:', err);
    res.status(500).json({ error: err.message });
  }
};

app.get('/api/dump-markdown', handleDumpMarkdown);
app.post('/api/dump-markdown', handleDumpMarkdown);

// GET /api/events (Frontend list API)
app.get('/api/events', async (req, res) => {
  try {
    const {
      city = 'san_francisco',
      locations,
      categories,
      slug,
      start_date,
      end_date,
      pagination_limit = '50',
      pagination_cursor,
      query,
      page = 1
    } = req.query;

    let locList = [];
    if (locations) {
      locList = String(locations).split(',').map(s => s.trim()).filter(Boolean);
    } else {
      locList = [city];
    }

    let catList = [];
    if (categories) {
      catList = String(categories).split(',').map(s => s.trim()).filter(Boolean);
    } else if (slug) {
      catList = [slug];
    }

    const startDateStr = parseMmDdYy(start_date);
    const endDateStr = parseMmDdYy(end_date);

    const result = await queryEventsCore({
      locations: locList,
      categories: catList,
      startDateStr,
      endDateStr,
      page: parseInt(page, 10) || 1,
      limit: Math.min(Math.max(parseInt(pagination_limit, 10) || 50, 1), 50),
      cursor: pagination_cursor || null,
      query
    });

    res.json({
      city: result.locations[0] || 'san_francisco',
      cityName: result.locationNames[0] || '旧金山',
      locations: result.locations,
      categories: result.categories,
      start_date: start_date || null,
      end_date: end_date || null,
      page: result.page,
      entries: result.entries,
      has_more: result.has_more,
      next_cursor: result.next_cursor
    });
  } catch (err) {
    console.error('Error in /api/events:', err);
    res.status(500).json({ error: err.message });
  }
});

// GET /api/event-detail
app.get('/api/event-detail', async (req, res) => {
  try {
    const { event_api_id } = req.query;
    if (!event_api_id) {
      return res.status(400).json({ error: 'event_api_id is required' });
    }

    const data = await fetchEventDetail(event_api_id);
    if (!data) {
      return res.status(404).json({ error: 'Event not found or failed to fetch' });
    }

    const markdown = proseMirrorToMarkdown(data.description_mirror);
    res.json({
      ...data,
      description_markdown: markdown.trim()
    });
  } catch (err) {
    console.error('Error fetching event detail:', err);
    res.status(500).json({ error: err.message });
  }
});

// Raw pass-through proxies
app.get('/discover/get-paginated-events', async (req, res) => {
  try {
    const targetUrl = new URL('https://api.luma.com/discover/get-paginated-events');
    for (const [k, v] of Object.entries(req.query)) {
      targetUrl.searchParams.set(k, v);
    }
    const response = await fetch(targetUrl.toString(), { headers: COMMON_HEADERS });
    const data = await response.json();
    res.status(response.status).json(data);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/event/get', async (req, res) => {
  try {
    const targetUrl = new URL('https://api.luma.com/event/get');
    for (const [k, v] of Object.entries(req.query)) {
      targetUrl.searchParams.set(k, v);
    }
    const response = await fetch(targetUrl.toString(), { headers: COMMON_HEADERS });
    const data = await response.json();
    res.status(response.status).json(data);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Hourly background auto-sync for Luma public vault
setInterval(() => {
  console.log('⏰ Running hourly Luma vault auto-sync...');
  syncLumaVault().catch(e => console.error('Hourly Luma sync error:', e.message));
}, 60 * 60 * 1000);

const server = app.listen(PORT, '127.0.0.1', () => {
  console.log(`Luma Vault & Proxy Service listening on http://127.0.0.1:${PORT}`);
});

function gracefulShutdown() {
  console.log('Received terminate signal, shutting down Luma service...');
  server.close(() => {
    process.exit(0);
  });
  setTimeout(() => {
    process.exit(1);
  }, 5000);
}

process.on('SIGTERM', gracefulShutdown);
process.on('SIGINT', gracefulShutdown);

module.exports = {
  dumpPageMarkdownCore,
  parseMmDdYy
};
