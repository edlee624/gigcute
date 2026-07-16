#!/usr/bin/env python3
"""For each new platform: harvest a few CC slugs, find a live one, and inspect the
job JSON — especially whether description is in the LIST (1-hop) or needs detail (2-hop)."""
import requests, re, json, time
UA = {"User-Agent": "Mozilla/5.0 (gigcute-discovery)"}
ci = requests.get("https://index.commoncrawl.org/collinfo.json", headers=UA, timeout=30).json()
CRAWL = ci[0]["id"]

def cc_slugs(pat, rx, limit=400):
    r = requests.get(f"https://index.commoncrawl.org/{CRAWL}-index", params={"url": pat, "output": "json", "fl": "url", "limit": limit}, headers=UA, timeout=90)
    s = []
    for line in r.text.splitlines():
        try: u = json.loads(line)["url"]
        except Exception: continue
        m = rx.search(u)
        if m and m.group(1).lower() not in ("www", "app", "api", "help"): s.append(m.group(1))
    return list(dict.fromkeys(s))

def show(name, slugs, fetch_jobs):
    for slug in slugs[:12]:
        try:
            jobs = fetch_jobs(slug)
        except Exception:
            jobs = None
        if jobs:
            j = jobs[0]
            print(f"\n== {name} (slug='{slug}', {len(jobs)} jobs) ==")
            print("  job keys:", list(j.keys())[:20])
            for k in ("title", "name", "jobOpeningName"):
                if k in j: print(f"  title<{k}>: {str(j[k])[:50]}")
            has_desc = [k for k in j if "descr" in k.lower() or k == "jobAd"]
            print("  description-ish keys:", has_desc)
            for k in ("published_on", "created_at", "releasedDate", "datePosted", "postedOn"):
                if k in j: print(f"  date<{k}>: {j[k]}")
            for k in ("location", "city", "locationCity", "locations"):
                if k in j: print(f"  loc<{k}>: {str(j[k])[:60]}")
            return
    print(f"\n== {name}: no live slug found in sample ==")

# SmartRecruiters
show("SmartRecruiters",
     cc_slugs("jobs.smartrecruiters.com/*", re.compile(r'jobs\.smartrecruiters\.com/([A-Za-z0-9._-]+)', re.I)),
     lambda s: (requests.get(f"https://api.smartrecruiters.com/v1/companies/{s}/postings?limit=5", headers=UA, timeout=12).json() or {}).get("content"))
# Workable
show("Workable",
     cc_slugs("apply.workable.com/*", re.compile(r'apply\.workable\.com/([a-z0-9._-]+)', re.I)),
     lambda s: (requests.get(f"https://apply.workable.com/api/v1/widget/accounts/{s}?details=true", headers=UA, timeout=12).json() or {}).get("jobs"))
# BambooHR
show("BambooHR",
     cc_slugs("*.bamboohr.com/*", re.compile(r'https?://([a-z0-9-]+)\.bamboohr\.com', re.I)),
     lambda s: (requests.get(f"https://{s}.bamboohr.com/careers/list", headers=UA, timeout=12).json() or {}).get("result"))
# Recruitee
show("Recruitee",
     cc_slugs("*.recruitee.com/*", re.compile(r'https?://([a-z0-9-]+)\.recruitee\.com', re.I)),
     lambda s: (requests.get(f"https://{s}.recruitee.com/api/offers/", headers=UA, timeout=12).json() or {}).get("offers"))
