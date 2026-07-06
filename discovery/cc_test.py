#!/usr/bin/env python3
"""Probe the Common Crawl index for ATS slugs — estimate yield before a full harvest."""
import requests, re, json
UA = {"User-Agent": "gigcute-discovery/1.0"}

# latest crawl id
ci = requests.get("https://index.commoncrawl.org/collinfo.json", headers=UA, timeout=30).json()
crawl = ci[0]["id"]
print("latest crawl:", crawl)

def sample(domain_pat, limit=3000):
    url = f"https://index.commoncrawl.org/{crawl}-index"
    try:
        r = requests.get(url, params={"url": domain_pat, "output": "json", "fl": "url", "limit": limit}, headers=UA, timeout=90)
        if r.status_code != 200:
            return f"HTTP {r.status_code}", set()
        urls = [json.loads(l)["url"] for l in r.text.splitlines() if l.strip()]
        return len(urls), urls
    except Exception as e:
        return f"ERR {type(e).__name__}: {e}", []

for pat, rx in [
    ("boards.greenhouse.io/*", r'greenhouse\.io/(?:embed/job_app\?for=)?([a-z0-9_-]+)'),
    ("jobs.lever.co/*", r'lever\.co/([a-z0-9_.-]+)'),
    ("jobs.ashbyhq.com/*", r'ashbyhq\.com/([a-z0-9_-]+)'),
    ("*.myworkdayjobs.com/*", r'([a-z0-9_-]+)\.(wd\d+)\.myworkdayjobs\.com'),
]:
    n, urls = sample(pat)
    slugs = set()
    for u in urls:
        m = re.search(rx, u, re.I)
        if m: slugs.add(m.group(1).lower())
    print(f"  {pat:32} urls={n}  unique_slugs={len(slugs)}  sample={list(slugs)[:8]}")
