import os
import requests
import json

TOKEN = os.environ.get("CANVAS_TOKEN", "")
HEADERS = {"Authorization": f"Bearer {TOKEN}"}

# Fetch page
url = "https://bcourses.berkeley.edu/api/v1/courses/1555334/pages/consent-under-the-influence"
r = requests.get(url, headers=HEADERS)
print("Page response:")
print(r.json().get("body", "")[:500])

# Fetch file info
file_url = "https://bcourses.berkeley.edu/api/v1/files/94768070"
r = requests.get(file_url, headers=HEADERS)
print("\nFile response:")
print(r.json())
