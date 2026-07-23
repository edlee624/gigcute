#!/usr/bin/env python3
"""
Sweep several Common Crawl archives for the newer ATS platforms.

The original four (greenhouse/lever/ashby/workday) were harvested across ~10
archives; the newer platforms were only ever harvested from the latest crawl, so
there's a lot of untapped supply. Each monthly archive surfaces a different slice
of boards (overlap is heavy, but the tail keeps paying).

Writes candidates_sweep.csv (platform,identifier — deduped across archives).
Run: python harvest_sweep.py [n_archives] [platform ...]
"""
import requests, re, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "candidates_sweep.csv")
UA = {"User-Agent": "gigcute-discovery/1.0"}

N_ARCHIVES = int(sys.argv[1]) if len(sys.argv) > 1 else 6
ONLY = [p.lower() for p in sys.argv[2:]] or None

ORA_RE = re.compile(r'https?://([a-z0-9.-]+)\.oraclecloud\.com/hcmUI/CandidateExperience/[a-z-]+/sites/([A-Za-z0-9_-]+)', re.I)
TARGETS = [
    ("oraclecloud",     None,                                                                   "*.oraclecloud.com/hcmUI/CandidateExperience/*"),
    ("bamboohr",        re.compile(r'https?://([a-z0-9][a-z0-9-]+)\.bamboohr\.com', re.I),      "*.bamboohr.com/*"),
    ("workable",        re.compile(r'apply\.workable\.com/([a-z0-9][a-z0-9._-]+)', re.I),       "apply.workable.com/*"),
    ("smartrecruiters", re.compile(r'jobs\.smartrecruiters\.com/([A-Za-z0-9][A-Za-z0-9._-]+)', re.I), "jobs.smartrecruiters.com/*"),
    ("recruitee",       re.compile(r'https?://([a-z0-9][a-z0-9-]+)\.recruitee\.com', re.I),     "*.recruitee.com/*"),
]
SKIP = {"embed", "robots", "sitemap", "sitemaps", "www", "assets", "static", "favicon", "apply",
        "job-boards", "boards", "api", "help", "blog", "jobs", "careers", "account", "support", "status"}

ci = requests.get("https://index.commoncrawl.org/collinfo.json", headers=UA, timeout=30).json()

FAILURES = []

def get(base, params, timeout, label=""):
    """Fetch with backoff. Returns None only after exhausting retries — callers MUST
    treat None as an error, not as an empty result (CC throttles hard under load and
    a swallowed 503 otherwise looks identical to 'no boards found')."""
    last = ""
    for attempt in range(5):
        try:
            r = requests.get(base, params=params, headers=UA, timeout=timeout)
            if r.ok:
                time.sleep(1.0)          # be polite; CC throttles aggressive clients
                return r
            last = f"HTTP {r.status_code}"
        except Exception as e:
            last = type(e).__name__
        time.sleep(5 * (attempt + 1))    # 5s,10s,15s,20s backoff
    FAILURES.append(f"{label}: {last}")
    print(f"    !! FAILED {label}: {last}", flush=True)
    return None

found = {}   # (platform, key) -> identifier
for idx in range(N_ARCHIVES):
    crawl = ci[idx]["id"]
    base = f"https://index.commoncrawl.org/{crawl}-index"
    print(f"\n=== archive {idx}: {crawl} ===", flush=True)
    for platform, rx, pat in TARGETS:
        if ONLY and platform not in ONLY:
            continue
        before = len(found)
        r = get(base, {"url": pat, "output": "json", "showNumPages": "true"}, 60, f"{crawl}/{platform}/numpages")
        if r is None:
            print(f"  {platform:16} SKIPPED (index unreachable) — not a zero result", flush=True)
            continue
        pages = r.json().get("pages", 0)
        for p in range(pages):
            r = get(base, {"url": pat, "output": "json", "fl": "url", "page": p}, 180, f"{crawl}/{platform}/p{p}")
            if not r:
                continue
            for line in r.text.splitlines():
                if not line.strip():
                    continue
                try:
                    u = json.loads(line)["url"]
                except Exception:
                    continue
                if platform == "oraclecloud":
                    m = ORA_RE.search(u)
                    if m:
                        pod, site = m.group(1).lower(), m.group(2)
                        found[("oraclecloud", f"{pod}|{site}")] = f"{pod}|{site}"
                else:
                    m = rx.search(u)
                    if m:
                        s = m.group(1) if platform == "smartrecruiters" else m.group(1).lower()
                        if s.lower() in SKIP or len(s) < 2:
                            continue
                        found[(platform, s)] = s
        print(f"  {platform:16} {pages} pages  +{len(found)-before} new  (running total {len(found)})", flush=True)

with open(OUT, "w", encoding="utf-8") as f:
    for (platform, _), ident in sorted(found.items()):
        f.write(f"{platform},{ident}\n")
print(f"\nDONE: {len(found)} unique candidates -> {OUT}", flush=True)
if FAILURES:
    print(f"WARNING: {len(FAILURES)} index requests failed — coverage is INCOMPLETE, re-run to fill gaps:", flush=True)
    for f in FAILURES[:15]:
        print(f"  {f}", flush=True)
