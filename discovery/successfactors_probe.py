#!/usr/bin/env python3
"""Feasibility probe for SAP SuccessFactors recruiting career sites. Goal: find a
PUBLIC, machine-readable job endpoint (JSON API / JSON-LD / sitemap), the way we
did for Oracle — SF career sites are usually Career Site Builder (CSB) or the older
Recruiting Marketing (RMK), hosted at careers.{co}.com / {co}.jobs / *.successfactors.com."""
import requests, re, json, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36",
      "Accept": "text/html,application/json,*/*"}

# (company careers landing) — these 40 were fingerprinted as SuccessFactors.
COMPANIES = {
    "Aflac": "https://www.aflac.com/about-aflac/careers.aspx",
    "Cintas": "https://careers.cintas.com/",
    "Altria": "https://www.altria.com/careers",
    "Ball": "https://jobs.ball.com/",
    "Dover": "https://careers.dovercorporation.com/",
    "Dexcom": "https://careers.dexcom.com/",
}

def dump(label, r):
    print(f"    {label}: HTTP {r.status_code}  final={r.url}  ({len(r.text)} bytes)")

for name, url in COMPANIES.items():
    print(f"\n===== {name} =====")
    try:
        r = requests.get(url, headers=UA, timeout=20, allow_redirects=True)
    except Exception as e:
        print(f"  landing ERR {type(e).__name__}: {e}"); continue
    dump("landing", r)
    host = re.match(r"https?://([^/]+)", str(r.url)).group(1)
    html = r.text
    # signals of which SF product + where jobs live
    for sig in ["successfactors", "careersite", "CareerSiteBuilder", "rmkcdn", "search-jobs",
                "/api/", "jobFeed", "sap-successfactors", "csbapp", "career?company="]:
        n = len(re.findall(re.escape(sig), html, re.I))
        if n:
            print(f"    signal '{sig}': x{n}")
    # candidate JSON endpoints to try
    base = f"https://{host}"
    tries = [
        ("sitemap", f"{base}/sitemap.xml"),
        ("csb searchJobs", f"{base}/api/careersite/searchJobs"),
        ("csb jobs", f"{base}/services/careersite/jobs"),
        ("rmk search-jobs", f"{base}/search-jobs/results?ActiveFacetID=0"),
    ]
    for lbl, turl in tries:
        try:
            tr = requests.get(turl, headers=UA, timeout=12)
            ct = tr.headers.get("content-type", "")[:30]
            hint = ""
            if "json" in ct:
                try: hint = f" keys={list(tr.json().keys())[:8]}"
                except Exception: hint = " (json parse fail)"
            elif "xml" in ct or "<urlset" in tr.text[:200] or "<sitemap" in tr.text[:200]:
                hint = f" urls~={tr.text.count('<loc>')}"
            print(f"    try {lbl}: HTTP {tr.status_code} {ct}{hint}")
        except Exception as e:
            print(f"    try {lbl}: ERR {type(e).__name__}")
    # JSON-LD JobPosting on the landing/any job link?
    blocks = re.findall(r'<script[^>]+application/ld\+json[^>]*>(.*?)</script>', html, re.S | re.I)
    types = []
    for b in blocks:
        try:
            o = json.loads(b.strip()); items = o if isinstance(o, list) else [o]
            types += [it.get("@type") for it in items if isinstance(it, dict)]
        except Exception: pass
    print(f"    JSON-LD blocks={len(blocks)} types={types[:6]}")
