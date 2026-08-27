const { chromium } = require('playwright');

(async () => {
  console.log("Launching browser...");
  try {
    const browser = await chromium.launch({ headless: true });
    const page = await browser.newPage();
    await page.goto('https://example.com');
    const title = await page.title();
    console.log(`Success! Page title is: ${title}`);
    await browser.close();
  } catch (error) {
    console.error("Failed to run Playwright:", error);
  }
})();
