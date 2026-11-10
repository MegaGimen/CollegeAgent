import { existsSync } from 'fs';
import { mkdir, writeFile } from 'fs/promises';
import { join } from 'path';

function detectBlocking(title, pageText) {
  const t = (title || '').toLowerCase();
  const txt = (pageText || '').toLowerCase().slice(0, 500);

  if (t.includes('just a moment') || t.includes('attention required')) return { blocked: true, reason: 'Cloudflare challenge' };
  if (t.includes('403') || t.includes('forbidden') || t.includes('access denied')) return { blocked: true, reason: 'Access denied (403)' };
  if (txt.includes("don't smell human") || txt.includes('are you a robot') || txt.includes('captcha')) return { blocked: true, reason: 'Bot detection triggered' };
  return { blocked: false };
}

async function scrapeWithFirecrawl(endpoint, apiKey, url) {
  const headers = { 'Content-Type': 'application/json' };
  if (apiKey) headers['Authorization'] = `Bearer ${apiKey}`;
  const response = await fetch(endpoint, { method: 'POST', headers, body: JSON.stringify({ url, formats: ['markdown'] }) });
  if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`);
  const json = await response.json();
  if (!json.success || !json.data) throw new Error(`Firecrawl failed`);
  return { markdown: json.data.markdown || '', title: json.data.metadata?.title || '' };
}

async function crawlPagesSync(urls) {
  const LOCAL_FIRECRAWL_URL = 'http://127.0.0.1:3002/v1/scrape';
  const API_FIRECRAWL_URL = 'https://api.firecrawl.dev/v1/scrape';
  const FIRECRAWL_API_KEY = process.env.FIRECRAWL_API_KEY || null;

  for (const url of urls) {
    try {
      console.log(`\n🕸️  Crawling ${url} (Local Firecrawl)...`);
      let scrapeResult;
      
      try {
        scrapeResult = await scrapeWithFirecrawl(LOCAL_FIRECRAWL_URL, null, url);
      } catch (err) {
        console.error(`  ⚠️ Local Firecrawl failed: ${err.message}. Attempting API fallback...`);
        scrapeResult = { markdown: '', title: '' };
      }

      let blockCheck = detectBlocking(scrapeResult.title, scrapeResult.markdown);
      
      if (blockCheck.blocked || !scrapeResult.markdown) {
        console.warn(`  ⚠️ Local blocked (${blockCheck.reason || 'No Content'}). Falling back to official API...`);
        scrapeResult = await scrapeWithFirecrawl(API_FIRECRAWL_URL, FIRECRAWL_API_KEY, url);
        blockCheck = detectBlocking(scrapeResult.title, scrapeResult.markdown);
        if (blockCheck.blocked) throw new Error(`Official API also blocked: ${blockCheck.reason}`);
        console.log(`  ✅ Official API fallback successful.`);
      }

      console.log(`  ✅ Done. Preview: ${scrapeResult.markdown.substring(0, 50).replace(/\n/g, ' ')}...`);
    } catch (err) {
      console.error(`  ❌ Failed to crawl ${url}: ${err.message}`);
    }
  }
}

(async () => {
  await crawlPagesSync(['https://www.spcberkeley.org/']);
  await crawlPagesSync(['https://me.berkeley.edu/graduate/gsis/']);
})();
