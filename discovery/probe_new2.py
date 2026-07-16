#!/usr/bin/env python3
import requests, re, json, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
UA = {"User-Agent": "Mozilla/5.0 (gigcute-discovery)"}
ci = requests.get("https://index.commoncrawl.org/collinfo.json", headers=UA, timeout=30).json()
CRAWL = ci[0]["id"]
def cc_slugs(pat, rx, limit=500):
    r = requests.get(f"https://index.commoncrawl.org/{CRAWL}-index", params={"url": pat, "output": "json", "fl": "url", "limit": limit}, headers=UA, timeout=90)
    s = []
    for line in r.text.splitlines():
        try: u = json.loads(line)["url"]
        except Exception: continue
        m = rx.search(u)
        if m and m.group(1).lower() not in ("www","app","api","help"): s.append(m.group(1))
    return list(dict.fromkeys(s))

# SmartRecruiters — list + detail
print("== SmartRecruiters ==")
for slug in ["PublicStorage", "Visa", "Bosch", "Ubisoft"]:
    r = requests.get(f"https://api.smartrecruiters.com/v1/companies/{slug}/postings?limit=3", headers=UA, timeout=12)
    if r.ok and (r.json().get("content")):
        p = r.json()["content"][0]
        print(f"  {slug}: LIST keys {list(p.keys())[:14]}")
        print(f"    name={p.get('name')} released={p.get('releasedDate')} loc={p.get('location')}")
        d = requests.get(f"https://api.smartrecruiters.com/v1/companies/{slug}/postings/{p['id']}", headers=UA, timeout=12)
        if d.ok:
            ja = d.json().get("jobAd", {})
            secs = (ja.get("sections") or {})
            print(f"    DETAIL jobAd.sections: {list(secs.keys())}  applyUrl={d.json().get('applyUrl') or d.json().get('postingUrl')}")
        break

# BambooHR — list + detail
print("\n== BambooHR ==")
for slug in cc_slugs("*.bamboohr.com/*", re.compile(r'https?://([a-z0-9-]+)\.bamboohr\.com', re.I)):
    r = requests.get(f"https://{slug}.bamboohr.com/careers/list", headers=UA, timeout=12)
    if r.ok and (r.json().get("result")):
        j = r.json()["result"][0]
        print(f"  {slug}: LIST keys {list(j.keys())}")
        d = requests.get(f"https://{slug}.bamboohr.com/careers/{j['id']}/detail", headers=UA, timeout=12)
        if d.ok:
            jo = (d.json().get("result") or {}).get("jobOpening", {})
            print(f"    DETAIL jobOpening keys: {list(jo.keys())[:20]}")
            print(f"    has description: {'description' in jo}  datePosted={jo.get('datePosted')}  compensation={jo.get('compensation')}")
        break

# Recruitee — list (is description included?)
print("\n== Recruitee ==")
for slug in cc_slugs("*.recruitee.com/*", re.compile(r'https?://([a-z0-9-]+)\.recruitee\.com', re.I)):
    r = requests.get(f"https://{slug}.recruitee.com/api/offers/", headers=UA, timeout=12)
    if r.ok and (r.json().get("offers")):
        o = r.json()["offers"][0]
        print(f"  {slug}: offer keys {list(o.keys())[:22]}")
        print(f"    title={o.get('title')} has_description={'description' in o} created={o.get('created_at')} loc={o.get('location')} url={o.get('careers_url')}")
        break
