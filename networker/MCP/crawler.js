import { chromium } from 'playwright';
import { existsSync } from 'fs';
import { mkdir, writeFile } from 'fs/promises';
import { join } from 'path';

// Helper to sanitize filenames
function sanitizeFilename(title, url) {
  if (!title) {
    return url.replace(/[^a-zA-Z0-9]/g, '_').substring(0, 50);
  }
  return title.replace(/[^a-zA-Z0-9 -]/g, '').trim().substring(0, 100) || 'untitled';
}

// Detect WAF blocks
function detectBlocking(title, bodyText) {
  title = title || '';
  bodyText = bodyText || '';
  if (title.includes('Just a moment') && bodyText.includes('Enable JavaScript and cookies')) return { blocked: true, reason: 'Cloudflare JS Challenge' };
  if (title.includes('Attention Required!') || title.includes('Access denied')) return { blocked: true, reason: 'Cloudflare Block' };
  if (bodyText.includes('Please verify you are a human')) return { blocked: true, reason: 'Captcha / Human Verification' };
  if (title.includes('403 Forbidden') || bodyText.includes('403 Forbidden')) return { blocked: true, reason: '403 Forbidden' };
  return { blocked: false };
}

export async function crawlPagesSync(urls, vaultDir) {
  if (!urls || urls.length === 0) return [];

  let browser;
  const results = [];

  try {
    browser = await chromium.launch({
      headless: true,
      args: [
        '--disable-blink-features=AutomationControlled',
        '--disable-features=IsolateOrigins,site-per-process',
      ],
    });
    const context = await browser.newContext({
      userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      viewport: { width: 1440, height: 900 },
      locale: 'en-US',
      timezoneId: 'America/Los_Angeles',
      extraHTTPHeaders: {
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
      },
    });

    if (vaultDir && !existsSync(vaultDir)) {
      await mkdir(vaultDir, { recursive: true });
    }

    for (const url of urls) {
      const page = await context.newPage();
      await page.route('**/*', (route) => {
        const type = route.request().resourceType();
        if (['image', 'media', 'font', 'stylesheet'].includes(type)) {
          route.abort();
        } else {
          route.continue();
        }
      });

      try {
        await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 20000 });
        let rawTitle = await page.title();
        const challengePatterns = ['Client Challenge', 'Just a moment', 'Attention Required'];
        const isChallenge = challengePatterns.some(p => rawTitle.includes(p));
        if (isChallenge) {
          for (let attempt = 0; attempt < 15; attempt++) {
            await page.waitForTimeout(1000);
            rawTitle = await page.title();
            if (!challengePatterns.some(p => rawTitle.includes(p)) && rawTitle) break;
          }
        }

        const bodyText = await page.evaluate(() => document.body?.innerText?.slice(0, 500) || '');
        const blockCheck = detectBlocking(rawTitle, bodyText);
        if (blockCheck.blocked) {
          results.push({
            url,
            title: rawTitle || 'Blocked',
            content: `[BLOCKED] This page could not be crawled: ${blockCheck.reason}.`,
            totalLines: 1,
            outboundLinks: [],
            crawlBlocked: true,
            blockReason: blockCheck.reason,
          });
          await page.close().catch(() => {});
          continue;
        }

        const cleanTitle = sanitizeFilename(rawTitle, url);
        const pageMarkdown = await page.evaluate(() => {
          const selectors = ['main', 'article', '#content', '#main', '.content', '.main'];
          let root = null;
          for (const sel of selectors) {
            root = document.querySelector(sel);
            if (root) break;
          }
          if (!root) root = document.body;

          function toMarkdown(node) {
            if (!node) return '';
            const ignoreTags = ['SCRIPT', 'STYLE', 'NAV', 'HEADER', 'FOOTER', 'IFRAME', 'NOSCRIPT', 'SVG', 'FORM', 'INPUT', 'BUTTON'];
            if (ignoreTags.includes(node.tagName)) return '';
            if (node.nodeType === Node.TEXT_NODE) return node.nodeValue.replace(/\s+/g, ' ');
            if (node.nodeType !== Node.ELEMENT_NODE) return '';
            const childrenMarkdown = Array.from(node.childNodes).map(child => toMarkdown(child)).join('');
            const tag = node.tagName;
            switch (tag) {
              case 'H1': return `\n# ${childrenMarkdown.trim()}\n`;
              case 'H2': return `\n## ${childrenMarkdown.trim()}\n`;
              case 'H3': return `\n### ${childrenMarkdown.trim()}\n`;
              case 'H4': return `\n#### ${childrenMarkdown.trim()}\n`;
              case 'H5': return `\n##### ${childrenMarkdown.trim()}\n`;
              case 'H6': return `\n###### ${childrenMarkdown.trim()}\n`;
              case 'P': return `\n${childrenMarkdown.trim()}\n`;
              case 'BR': return `\n`;
              case 'STRONG': case 'B': return `**${childrenMarkdown.trim()}**`;
              case 'EM': case 'I': return `*${childrenMarkdown.trim()}*`;
              case 'LI': return `\n- ${childrenMarkdown.trim()}`;
              case 'UL': return `\n${childrenMarkdown.trim()}\n`;
              case 'OL': return `\n${childrenMarkdown.trim()}\n`;
              case 'A': {
                let href = node.getAttribute('href');
                const text = childrenMarkdown.trim();
                if (!text) return '';
                if (href) {
                  try {
                    const absUrl = new URL(href, window.location.href);
                    href = absUrl.toString();
                    const isImg = /\.(png|jpg|jpeg|gif|svg)$/i.test(absUrl.pathname);
                    if (isImg) return `![${text}](${href})`;
                  } catch {}
                }
                return href ? `[${text}](${href})` : text;
              }
              case 'IMG': {
                const src = node.getAttribute('src');
                const alt = node.getAttribute('alt') || '';
                if (!src) return '';
                try { return `![${alt}](${new URL(src, window.location.href).toString()})`; }
                catch { return `![${alt}](${src})`; }
              }
              default: return childrenMarkdown;
            }
          }
          return toMarkdown(root).replace(/\n{3,}/g, '\n\n').trim();
        });

        const outboundLinks = await page.evaluate(() => {
          return Array.from(document.querySelectorAll('a'))
            .map(a => ({
              href: a.href,
              text: (a.innerText || a.getAttribute('title') || '').trim(),
            }))
            .filter(item => item.href)
            .map(item => {
              try {
                const absUrl = new URL(item.href, window.location.href);
                if (absUrl.protocol === 'http:' || absUrl.protocol === 'https:') {
                  return { url: absUrl.toString(), title: item.text };
                }
              } catch {}
              return null;
            })
            .filter(item => item !== null);
        });

        const uniqueLinks = Array.from(new Map(outboundLinks.map(l => [l.url, l])).values());
        
        let fileMarkdown = `# ${rawTitle}\n\n**URL**: ${url}\n\n${pageMarkdown}`;
        if (uniqueLinks.length > 0) {
          fileMarkdown += '\n\n## Outbound Links\n\n';
          for (const link of uniqueLinks) {
            const cleanLinkTitle = sanitizeFilename(link.title, link.url);
            fileMarkdown += `- [[${cleanLinkTitle}]] ([${link.title || cleanLinkTitle}](${link.url}))\n`;
          }
        }
        if (vaultDir) {
           const filename = `${cleanTitle}_${Date.now().toString().slice(-4)}.md`;
           const filepath = join(vaultDir, filename);
           await writeFile(filepath, fileMarkdown, 'utf-8');
        }

        results.push({
          url,
          title: rawTitle,
          content: fileMarkdown,
          totalLines: fileMarkdown.split('\n').length,
          outboundLinks: uniqueLinks,
        });

      } catch (err) {
        results.push({
          url,
          title: 'Error',
          content: `[ERROR] Failed to crawl page: ${err.message}`,
          totalLines: 1,
          outboundLinks: [],
          crawlBlocked: true,
          error: err.message,
        });
      } finally {
        await page.close().catch(() => {});
      }
    }
  } finally {
    if (browser) await browser.close();
  }
  return results;
}
