import asyncio
from crawl4ai import AsyncWebCrawler

async def main():
    print("Starting Crawl4AI extraction...")
    try:
        async with AsyncWebCrawler(verbose=True) as crawler:
            result = await crawler.arun(
                url="https://me.berkeley.edu/graduate/gsis/",
                magic=True, # enables stealth/cloudflare bypass heuristics
            )
            
            if result.success:
                print("--- MARKDOWN PREVIEW ---")
                print(result.markdown[:1500] if result.markdown else "No Markdown generated.")
            else:
                print(f"Extraction failed: {result.error_message}")
                print(f"Status Code: {result.status_code}")
    except Exception as e:
        print(f"Error during crawl: {e}")

if __name__ == "__main__":
    asyncio.run(main())
