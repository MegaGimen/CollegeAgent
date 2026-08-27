import json
import os
import requests
from bs4 import BeautifulSoup
import pymupdf

TOKEN = os.environ.get("CANVAS_TOKEN", "")
HEADERS = {"Authorization": f"Bearer {TOKEN}"}

INDEX_PATH = "/home/collegeagent/networker/MCP/private_vaults/2420010e-ab11-40b5-b9df-be390b505dc5/index.json"

with open(INDEX_PATH, "r", encoding="utf-8") as f:
    data = json.load(f)

for node_id, node in data.get("nodes", {}).items():
    if "content" not in node or not node["content"].strip():
        url = node.get("url", "")
        if not url:
            continue
            
        print(f"Fetching {node_id}: {url}")
        content = ""
        
        try:
            if "care.berkeley.edu" in url:
                r = requests.get(url, timeout=10)
                soup = BeautifulSoup(r.text, 'html.parser')
                content = soup.get_text(separator='\n', strip=True)
                
            elif "hp-cusp.pdf" in url:
                r = requests.get(url, timeout=10)
                with open("/tmp/temp.pdf", "wb") as pdf_f:
                    pdf_f.write(r.content)
                doc = pymupdf.open("/tmp/temp.pdf")
                content = "\n".join([page.get_text() for page in doc])
                
            elif "bcourses.berkeley.edu/courses/1555334/pages/module-3" in url:
                r = requests.get("https://bcourses.berkeley.edu/api/v1/courses/1555334/pages/module-3", headers=HEADERS, timeout=10)
                if r.status_code == 200:
                    html_body = r.json().get("body", "")
                    soup = BeautifulSoup(html_body, 'html.parser')
                    content = soup.get_text(separator='\n', strip=True)
                    
            elif "files/94768070/download" in url:
                # Need to get the actual download URL for the file via Canvas API
                # Or just download it directly using the token
                r = requests.get(url, headers=HEADERS, timeout=10)
                with open("/tmp/temp2.pdf", "wb") as pdf_f:
                    pdf_f.write(r.content)
                try:
                    doc = pymupdf.open("/tmp/temp2.pdf")
                    content = "\n".join([page.get_text() for page in doc])
                except Exception as e:
                    print("Error parsing as PDF, maybe not a PDF?", e)
                    content = "File downloaded but could not be parsed as PDF. Size: " + str(len(r.content))

            if content:
                node["content"] = f"# {node.get('title', 'Untitled')}\n\n**URL**: {url}\n\n{content}"
                print(f" -> Success! Length: {len(node['content'])}")
                
        except Exception as e:
            print(f" -> Error: {e}")

with open(INDEX_PATH, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)

print("Saved index.json.")
