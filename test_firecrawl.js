const url = 'https://me.berkeley.edu/graduate/gsis/';
const firecrawlUrl = 'http://127.0.0.1:3002/v1/scrape';

async function test() {
  console.log(`Sending scrape request to Firecrawl for: ${url}...`);
  try {
    const response = await fetch(firecrawlUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        url: url,
        formats: ['markdown']
      })
    });

    if (!response.ok) {
      console.error(`Error HTTP ${response.status}:`, await response.text());
      return;
    }

    const json = await response.json();
    if (json.success && json.data) {
      const markdown = json.data.markdown || '';
      console.log('--- MARKDOWN PREVIEW ---');
      console.log(markdown.substring(0, 500) + '...\n\n');

      // Extract outbound links
      const linkRegex = /\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g;
      const links = [];
      let match;
      while ((match = linkRegex.exec(markdown)) !== null) {
        links.push({ title: match[1].replace(/\n/g, ' ').trim(), url: match[2] });
      }

      // Deduplicate
      const uniqueLinks = links.filter((v, i, a) => a.findIndex(t => (t.url === v.url)) === i);
      
      console.log(`--- OUTBOUND LINKS (${uniqueLinks.length}) ---`);
      console.log(uniqueLinks.slice(0, 10)); // Show top 10
    } else {
      console.log("No data returned:", json);
    }
  } catch (err) {
    console.error("Fetch error:", err.message);
  }
}

test();
