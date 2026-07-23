#!/usr/bin/env python3
"""
Bulk-harvest ATS company slugs from the Common Crawl index (all pages).
Writes candidates_cc.csv as `platform,identifier` (workday = tenant|dc|site).
Run: python cc_harvest.py   (takes ~10-30 min; prints progress)
"""
import requests, re, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "candidates_cc.csv")
UA = {"User-Agent": "gigcute-discovery/1.0"}

ci = requests.get("https://index.commoncrawl.org/collinfo.json", headers=UA, timeout=30).json()
_idx = int(sys.argv[1]) if len(sys.argv) > 1 else 0   # 0 = latest crawl, 1 = previous, ...
ONLY = sys.argv[2].lower() if len(sys.argv) > 2 else None  # optional: harvest one platform
if ONLY:
    # Per-platform AND per-archive, so repeated runs accumulate instead of
    # clobbering (each monthly archive surfaces a different slice of boards).
    OUT = os.path.join(HERE, f"candidates_cc_{ONLY}_{_idx}.csv")
CRAWL = ci[_idx]["id"]
BASE = f"https://index.commoncrawl.org/{CRAWL}-index"
print(f"crawl {CRAWL}", flush=True)

def num_pages(pat):
    for _ in range(3):
        try:
            r = requests.get(BASE, params={"url": pat, "output": "json", "showNumPages": "true"}, headers=UA, timeout=60)
            if r.ok:
                return r.json().get("pages", 0)
        except Exception:
            time.sleep(3)
    return 0

def fetch_page(pat, page):
    for _ in range(3):
        try:
            r = requests.get(BASE, params={"url": pat, "output": "json", "fl": "url", "page": page}, headers=UA, timeout=180)
            if r.ok:
                return r.text
        except Exception:
            time.sleep(4)
    return ""

WD_RE = re.compile(r'https?://([a-z0-9_-]+)\.(wd\d+)\.myworkdayjobs\.com/(?:[a-z]{2}-[A-Za-z]{2}/)?([A-Za-z0-9_-]+)', re.I)
# Oracle Cloud Recruiting (Fusion HCM): pod = full subdomain chain (e.g. "ejgl.fa.ap1"),
# site = the CandidateExperience site code (e.g. "CX_1", "UOW"). Identifier = pod|site.
ORA_RE = re.compile(r'https?://([a-z0-9.-]+)\.oraclecloud\.com/hcmUI/CandidateExperience/[a-z-]+/sites/([A-Za-z0-9_-]+)', re.I)
GH_RE = re.compile(r'greenhouse\.io/(?:embed/job_app\?for=)?([a-z0-9_-]+)', re.I)
# (platform, regex, cc-query-pattern) — two Greenhouse domains, Lever, Ashby, Workday
SOURCES = [
    ("greenhouse",     GH_RE, "boards.greenhouse.io/*"),
    ("greenhouse",     GH_RE, "job-boards.greenhouse.io/*"),
    ("lever",          re.compile(r'jobs\.lever\.co/([a-z0-9][a-z0-9_.-]+)', re.I), "jobs.lever.co/*"),
    ("ashby",          re.compile(r'jobs\.ashbyhq\.com/([a-z0-9][a-z0-9_-]+)', re.I), "jobs.ashbyhq.com/*"),
    ("workday",        None, "*.myworkdayjobs.com/*"),
    ("smartrecruiters", re.compile(r'jobs\.smartrecruiters\.com/([A-Za-z0-9][A-Za-z0-9._-]+)', re.I), "jobs.smartrecruiters.com/*"),
    ("workable",       re.compile(r'apply\.workable\.com/([a-z0-9][a-z0-9._-]+)', re.I), "apply.workable.com/*"),
    ("bamboohr",       re.compile(r'https?://([a-z0-9][a-z0-9-]+)\.bamboohr\.com', re.I), "*.bamboohr.com/*"),
    ("recruitee",      re.compile(r'https?://([a-z0-9][a-z0-9-]+)\.recruitee\.com', re.I), "*.recruitee.com/*"),
    ("oraclecloud",    None, "*.oraclecloud.com/hcmUI/CandidateExperience/*"),
]
SKIP = {"embed", "robots", "sitemap", "sitemaps", "www", "assets", "static", "favicon", "apply", "job-boards",
        "boards", "api", "help", "blog", "jobs", "careers", "account", "support", "status"}

found = {}  # (platform, slugkey) -> identifier
for platform, rx, pat in SOURCES:
    if ONLY and platform != ONLY:
        continue
    pages = num_pages(pat)
    print(f"\n{platform}: {pages} pages", flush=True)
    before = len(found)
    for p in range(pages):
        text = fetch_page(pat, p)
        for line in text.splitlines():
            if not line.strip():
                continue
            try:
                u = json.loads(line)["url"]
            except Exception:
                continue
            if platform == "workday":
                m = WD_RE.search(u)
                if m:
                    tenant = m.group(1).lower()
                    if tenant in SKIP:
                        continue
                    found[("workday", tenant)] = f"{tenant}|{m.group(2).lower()}|{m.group(3)}"
            elif platform == "oraclecloud":
                m = ORA_RE.search(u)
                if m:
                    pod, site = m.group(1).lower(), m.group(2)
                    # One pod can host several sites (distinct boards) — key on both.
                    found[("oraclecloud", f"{pod}|{site}")] = f"{pod}|{site}"
            else:
                m = rx.search(u)
                if m:
                    # SmartRecruiters company slugs are case-sensitive; others are lowercase subdomains.
                    s = m.group(1) if platform == "smartrecruiters" else m.group(1).lower()
                    if s.lower() in SKIP or len(s) < 2:
                        continue
                    found[(platform, s)] = s
        if (p + 1) % 5 == 0 or p == pages - 1:
            print(f"  page {p+1}/{pages}  total unique so far: {len(found)}", flush=True)
    print(f"{platform}: +{len(found)-before} unique", flush=True)

with open(OUT, "w", encoding="utf-8") as f:
    for (platform, _), ident in sorted(found.items()):
        f.write(f"{platform},{ident}\n")
print(f"\nDONE: {len(found)} unique candidates -> {OUT}", flush=True)
