import sys
import json
import os
import re
import requests
from bs4 import BeautifulSoup
import pymupdf
import uuid

if len(sys.argv) < 3:
    print("Usage: python3 expand_1hop.py <user_id> <token>")
    sys.exit(1)

user_id = sys.argv[1]
token = sys.argv[2]
HEADERS = {
    "Authorization": f"Bearer {token}",
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36"
}

INDEX_PATH = f"/home/collegeagent/networker/MCP/private_vaults/{user_id}/index.json"

if not os.path.exists(INDEX_PATH):
    print("No index.json found.")
    sys.exit(0)

with open(INDEX_PATH, "r", encoding="utf-8") as f:
    data = json.load(f)

changed = False

for node_id, node in data.get("nodes", {}).items():
    current_content = node.get("content", "")
    if not current_content.strip() or "No extractable text found in this document/page" in current_content:
        url = node.get("url", "")
        if not url:
            continue
            
        print(f"Fetching {node_id}: {url}")
        content = ""
        
        try:
            # 1. Canvas Page
            page_match = re.search(r"bcourses\.berkeley\.edu/courses/(\d+)/pages/([^/\?]+)", url)
            # 2. Canvas File
            file_match = re.search(r"bcourses\.berkeley\.edu/courses/(\d+)/files/(\d+)", url)
            
            if page_match:
                course_id, page_id = page_match.groups()
                api_url = f"https://bcourses.berkeley.edu/api/v1/courses/{course_id}/pages/{page_id}"
                r = requests.get(api_url, headers=HEADERS, timeout=10)
                if r.status_code == 200:
                    html_body = r.json().get("body", "")
                    soup = BeautifulSoup(html_body, 'html.parser')
                    content = soup.get_text(separator='\n', strip=True)
                else:
                    content = f"Failed to fetch Canvas Page. HTTP {r.status_code}"
                    
            elif file_match or url.lower().split('?')[0].endswith('.pdf'):
                # Treat as file/PDF
                r = requests.get(url, headers=HEADERS, timeout=15)
                tmp_path = f"/tmp/{uuid.uuid4().hex}.pdf"
                with open(tmp_path, "wb") as pdf_f:
                    pdf_f.write(r.content)
                try:
                    doc = pymupdf.open(tmp_path)
                    content = "\n".join([page.get_text() for page in doc])
                    doc.close()
                except Exception as e:
                    # Not a valid PDF
                    soup = BeautifulSoup(r.content, 'html.parser')
                    text = soup.get_text(separator='\n', strip=True)
                    if text:
                        content = text
                    else:
                        content = f"Binary file or unparseable content. Size: {len(r.content)} bytes."
                finally:
                    if os.path.exists(tmp_path):
                        os.remove(tmp_path)
                        
            else:
                # Generic external webpage
                r = requests.get(url, headers=HEADERS, timeout=15)
                from readability import Document
                doc = Document(r.text)
                soup = BeautifulSoup(doc.summary(), 'html.parser')
                content = soup.get_text(separator='\n', strip=True)
                if not content:
                    # Fallback if readability fails to find main article
                    soup = BeautifulSoup(r.text, 'html.parser')
                    for tag in soup(['nav', 'header', 'footer', 'script', 'style', 'aside', 'noscript']):
                        tag.decompose()
                    content = soup.get_text(separator='\n', strip=True)

            if not content:
                content = "No extractable text found in this document/page."
                
            node["content"] = f"# {node.get('title', 'Untitled')}\n\n**URL**: {url}\n\n{content}"
            print(f" -> Success! Length: {len(node['content'])}")
            changed = True
                
        except Exception as e:
            print(f" -> Error: {e}")

if changed:
    with open(INDEX_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    print("Saved index.json.")
    
    # Trigger reindex via AutoRAG
    try:
        requests.post("http://127.0.0.1:8002/reindex", timeout=5)
        print("Triggered /reindex.")
    except Exception as e:
        print("Error triggering reindex:", e)
else:
    print("No nodes needed fetching.")
