const url = 'https://www.spcberkeley.org/';
const firecrawlUrl = 'http://127.0.0.1:3002/v1/scrape';

async function test() {
  console.log(`Sending scrape request to Local Firecrawl for: ${url}...`);
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
      console.log(markdown.substring(0, 1500) + '\n...\n');

      const linkRegex = /\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g;
      const links = [];
      let match;
      while ((match = linkRegex.exec(markdown)) !== null) {
        links.push({ title: match[1].replace(/\n/g, ' ').trim(), url: match[2] });
      }

      const uniqueLinks = links.filter((v, i, a) => a.findIndex(t => (t.url === v.url)) === i);
      
      console.log(`--- OUTBOUND LINKS (${uniqueLinks.length}) ---`);
      console.log(uniqueLinks.slice(0, 5));
    } else {
      console.log("No data returned or success=false:", json);
    }
  } catch (err) {
    console.error("Fetch error:", err.message);
  }
}

test();
