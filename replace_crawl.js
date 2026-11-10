const fs = require('fs');
const filepath = '/home/collegeagent/networker/MCP/server.js.bak';
let code = fs.readFileSync(filepath, 'utf8');

// Remove playwright import
code = code.replace(/import \{ chromium \} from 'playwright';/, '// Playwright removed');

const newFunc = `
/**
 * Extract outbound links from markdown via regex.
 */
function extractOutboundLinks(markdown) {
  const linkRegex = /\\[([^\\]]+)\\]\\((https?:\\/\\/[^\\s)]+)\\)/g;
  const links = [];
  let match;
  while ((match = linkRegex.exec(markdown)) !== null) {
    links.push({ title: match[1].replace(/\\n/g, ' ').trim(), url: match[2] });
  }
  return links.filter((v, i, a) => a.findIndex(t => t.url === v.url) === i);
}

/**
 * Perform a single scrape using a specific Firecrawl endpoint.
 */
async function scrapeWithFirecrawl(endpoint, apiKey, url) {
  const headers = { 'Content-Type': 'application/json' };
  if (apiKey) {
    headers['Authorization'] = \`Bearer \${apiKey}\`;
  }
  
  const response = await fetch(endpoint, {
    method: 'POST',
    headers,
    body: JSON.stringify({ url, formats: ['markdown'] })
  });

  if (!response.ok) {
    throw new Error(\`HTTP \${response.status}: \${await response.text()}\`);
  }

  const json = await response.json();
  if (!json.success || !json.data) {
    throw new Error(\`Firecrawl failed: \${JSON.stringify(json.error || json)}\`);
  }
  
  return {
    markdown: json.data.markdown || '',
    title: json.data.metadata?.title || ''
  };
}

async function crawlPagesSync(urls, vaultDir) {
  if (!urls || urls.length === 0) return [];
  
  const results = [];
  const LOCAL_FIRECRAWL_URL = 'http://127.0.0.1:3002/v1/scrape';
  const API_FIRECRAWL_URL = 'https://api.firecrawl.dev/v1/scrape';
  const FIRECRAWL_API_KEY = process.env.FIRECRAWL_API_KEY || null;

  const { existsSync } = require('fs');
  const { mkdir, writeFile } = require('fs/promises');
  const { join } = require('path');

  if (!existsSync(vaultDir)) {
    await mkdir(vaultDir, { recursive: true });
  }

  for (const url of urls) {
    try {
      console.log(\`\\n🕸️  Crawling \${url} (Local Firecrawl)...\`);
      let scrapeResult;
      
      try {
        scrapeResult = await scrapeWithFirecrawl(LOCAL_FIRECRAWL_URL, null, url);
      } catch (err) {
        console.error(\`  ⚠️ Local Firecrawl failed: \${err.message}. Attempting API fallback...\`);
        scrapeResult = { markdown: '', title: '' };
      }

      let blockCheck = detectBlocking(scrapeResult.title, scrapeResult.markdown);
      
      if (blockCheck.blocked || !scrapeResult.markdown) {
        console.warn(\`  ⚠️ Local blocked (\${blockCheck.reason || 'No Content'}). Falling back to official API...\`);
        if (!FIRECRAWL_API_KEY) {
          throw new Error('Fallback failed: FIRECRAWL_API_KEY is not set in environment.');
        }
        
        scrapeResult = await scrapeWithFirecrawl(API_FIRECRAWL_URL, FIRECRAWL_API_KEY, url);
        blockCheck = detectBlocking(scrapeResult.title, scrapeResult.markdown);
        
        if (blockCheck.blocked) {
           throw new Error(\`Official API also blocked: \${blockCheck.reason}\`);
        }
        console.log(\`  ✅ Official API fallback successful.\`);
      }

      const rawTitle = scrapeResult.title || 'Untitled';
      const cleanTitle = sanitizeFilename(rawTitle, url);
      const pageMarkdown = scrapeResult.markdown;
      const outboundLinks = extractOutboundLinks(pageMarkdown);

      let mdContent = \`# \${cleanTitle}\\n\\n\`;
      mdContent += \`- **Source URL**: [\${url}](\${url})\\n\`;
      mdContent += \`- **Crawled At**: \${new Date().toISOString()}\\n\\n\`;
      mdContent += \`## Content\\n\\n\`;
      mdContent += (pageMarkdown || '*No text content extracted.*') + '\\n\\n';
      mdContent += \`## Outbound Links\\n\\n\`;

      if (outboundLinks.length > 0) {
        for (const link of outboundLinks) {
          const cleanLinkTitle = sanitizeFilename(link.title, link.url);
          mdContent += \`- [[\${cleanLinkTitle}]] ([\${link.title || cleanLinkTitle}](\${link.url}))\\n\`;
        }
      } else {
        mdContent += 'No outbound links found on this page.\\n';
      }

      const filePath = join(vaultDir, \`\${cleanTitle}.md\`);
      await writeFile(filePath, mdContent, 'utf-8');
      console.error(\`  📄 Saved: \${cleanTitle}.md → \${vaultDir}\`);

      const contentLines = mdContent.split('\\n');
      const pad = String(contentLines.length).length;
      const numberedContent = contentLines.map((line, i) =>
        \`\${String(i + 1).padStart(pad, ' ')}|\${line}\`
      ).join('\\n');

      results.push({
        url,
        title: cleanTitle,
        content: numberedContent,
        totalLines: contentLines.length,
        outboundLinks: outboundLinks.map(l => ({
          title: sanitizeFilename(l.title, l.url),
          url: l.url,
        })),
      });

    } catch (err) {
      console.error(\`  ⚠️  Crawl failed for \${url}: \${err.message}\`);
      results.push({
        url,
        title: sanitizeFilename(null, url),
        content: \`[BLOCKED] Crawl failed: \${err.message}\`,
        totalLines: 1,
        outboundLinks: [],
        crawlError: err.message,
      });
    }
  }

  return results;
}
`;

// Replace from 'async function crawlPagesSync' until '// ── Debounced reindex'
const startIdx = code.indexOf('async function crawlPagesSync(urls, vaultDir) {');
const endMarker = '// ── Debounced reindex: triggers full pipeline';
const endIdx = code.indexOf(endMarker);

if (startIdx !== -1 && endIdx !== -1) {
  const newCode = code.substring(0, startIdx) + newFunc + '\n' + code.substring(endIdx);
  fs.writeFileSync('/home/collegeagent/networker/MCP/server.js', newCode);
  console.log("Successfully replaced crawlPagesSync.");
} else {
  console.log("Indices not found.", startIdx, endIdx);
}
