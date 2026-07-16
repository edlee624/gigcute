#!/usr/bin/env python3
"""Size the new-ATS-platform opportunity in Common Crawl (full pagination)."""
import requests, re, json, time
UA = {"User-Agent": "gigcute-discovery/1.0"}
ci = requests.get("https://index.commoncrawl.org/collinfo.json", headers=UA, timeout=30).json()
CRAWL = ci[0]["id"]; BASE = f"https://index.commoncrawl.org/{CRAWL}-index"
print(f"crawl {CRAWL}\n")

def pages(pat):
    for _ in range(3):
        try:
            r = requests.get(BASE, params={"url": pat, "output": "json", "showNumPages": "true"}, headers=UA, timeout=60)
            if r.ok: return r.json().get("pages", 0)
        except Exception: time.sleep(3)
    return 0

def harvest(pat, rx, single_group=True):
    slugs = set()
    n = pages(pat)
    for p in range(n):
        for _ in range(3):
            try:
                r = requests.get(BASE, params={"url": pat, "output": "json", "fl": "url", "page": p}, headers=UA, timeout=150)
                if r.ok: break
            except Exception: time.sleep(4)
        else: continue
        for line in r.text.splitlines():
            if not line.strip(): continue
            try: u = json.loads(line)["url"]
            except Exception: continue
            m = rx.search(u)
            if m: slugs.add(m.group(1).lower())
    return n, slugs

targets = [
    ("SmartRecruiters", "jobs.smartrecruiters.com/*", re.compile(r'jobs\.smartrecruiters\.com/([A-Za-z0-9._-]+)', re.I)),
    ("Workable",        "apply.workable.com/*",       re.compile(r'apply\.workable\.com/([a-z0-9._-]+)', re.I)),
    ("iCIMS",           "*.icims.com/*",              re.compile(r'https?://([a-z0-9-]+)\.icims\.com', re.I)),
    ("Recruitee",       "*.recruitee.com/*",          re.compile(r'https?://([a-z0-9-]+)\.recruitee\.com', re.I)),
    ("BambooHR",        "*.bamboohr.com/*",           re.compile(r'https?://([a-z0-9-]+)\.bamboohr\.com', re.I)),
]
SKIP = {"www", "app", "api", "help", "jobs", "careers", "apply", "static", "assets", "blog"}
for name, pat, rx in targets:
    n, slugs = harvest(pat, rx)
    slugs -= SKIP
    print(f"{name:16} {n} pages  ->  {len(slugs)} unique portals/slugs")
