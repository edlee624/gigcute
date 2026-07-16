#!/usr/bin/env python3
"""Feasibility probe for Oracle Cloud Recruiting (Fusion HCM / ORC — the Taleo
successor). Boards live at {pod}.fa.{dc}.oraclecloud.com/hcmUI/CandidateExperience/
en/sites/{siteCode}/... and expose a public JSON REST API. Two questions:
  1) How discoverable are boards in Common Crawl? (need pod host + site code)
  2) What's the API shape? (list 1-hop vs detail 2-hop for the description)
"""
import requests, re, json, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
UA = {"User-Agent": "Mozilla/5.0 (gigcute-discovery)", "Accept": "application/json"}

ci = requests.get("https://index.commoncrawl.org/collinfo.json", headers=UA, timeout=30).json()
CRAWL = ci[0]["id"]
BASE = f"https://index.commoncrawl.org/{CRAWL}-index"
print(f"crawl {CRAWL}\n")

# pod host = full subdomain chain before .oraclecloud.com; site code = after /sites/
URL_RE = re.compile(r'https?://([a-z0-9.-]+)\.oraclecloud\.com/hcmUI/CandidateExperience/[a-z-]+/sites/([A-Za-z0-9_-]+)', re.I)

def cc_pages(pat):
    r = requests.get(BASE, params={"url": pat, "output": "json", "showNumPages": "true"}, headers=UA, timeout=60)
    return r.json().get("pages", 0) if r.ok else 0

def cc_harvest(pat, max_pages=2):
    boards = {}
    n = cc_pages(pat)
    for p in range(min(n, max_pages)):
        r = requests.get(BASE, params={"url": pat, "output": "json", "fl": "url", "page": p}, headers=UA, timeout=120)
        for line in r.text.splitlines():
            try: u = json.loads(line)["url"]
            except Exception: continue
            m = URL_RE.search(u)
            if m:
                boards[(m.group(1).lower(), m.group(2))] = f"https://{m.group(1)}.oraclecloud.com"
    return n, boards

def list_jobs(host, site, limit=10):
    url = (f"{host}/hcmRestApi/resources/latest/recruitingCEJobRequisitions"
           f"?onlyData=true&expand=requisitionList.secondaryLocations,requisitionList.workLocation"
           f"&finder=findReqs;siteNumber={site},limit={limit},sortBy=POSTING_DATES_DESC")
    r = requests.get(url, headers=UA, timeout=15)
    if not r.ok: return None, r.status_code
    items = (r.json().get("items") or [])
    return (items[0].get("requisitionList") if items else []), 200

def detail(host, site, reqid):
    url = (f"{host}/hcmRestApi/resources/latest/recruitingCEJobRequisitionDetails"
           f'?expand=all&onlyData=true&finder=ByReqId;Id="{reqid}",siteNumber={site}')
    r = requests.get(url, headers=UA, timeout=15)
    if not r.ok: return None
    items = (r.json().get("items") or [])
    return items[0] if items else None

print("== Common Crawl discoverability ==")
n, boards = cc_harvest("*.oraclecloud.com/hcmUI/CandidateExperience/*", max_pages=2)
print(f"  {n} total CC pages for the pattern; sampled {len(boards)} unique (pod, site) from 2 pages")
for (host, site), _ in list(boards.items())[:8]:
    print(f"    {host}.oraclecloud.com  site={site}")

print("\n== API shape (first few live boards) ==")
tested = 0
for (host, site), hosturl in boards.items():
    if tested >= 4: break
    try:
        jobs, code = list_jobs(hosturl, site, 5)
    except Exception as e:
        print(f"  {host}/{site}: ERR {type(e).__name__}"); continue
    if code != 200:
        print(f"  {host}/{site}: list HTTP {code}"); continue
    if not jobs:
        print(f"  {host}/{site}: 0 jobs (site code may differ from URL segment)"); continue
    tested += 1
    j = jobs[0]
    print(f"\n  LIVE {host}  site={site}  ({len(jobs)} jobs)")
    print("    list keys:", [k for k in j.keys()][:22])
    print(f"    Title={j.get('Title')!r}  Posted={j.get('PostedDate')}  Loc={j.get('PrimaryLocation')}")
    desc_in_list = [k for k in j if 'escription' in k]
    print("    description-ish in LIST:", desc_in_list)
    d = detail(hosturl, site, j.get("Id"))
    if d:
        dk = [k for k in d if 'escription' in k or 'ualification' in k]
        print("    DETAIL description keys:", dk)
        ext = d.get("ExternalDescriptionStr") or ""
        print(f"    ExternalDescriptionStr len={len(ext)}  ExternalUrl?={bool(d.get('ExternalUrl') or d.get('ApplyUrl'))}")
print(f"\ndone (tested {tested} live boards)")
