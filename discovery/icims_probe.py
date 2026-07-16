#!/usr/bin/env python3
"""Probe iCIMS: does the search page list jobs, and do job pages carry JSON-LD
(schema.org JobPosting)? That determines whether iCIMS is cleanly ingestible."""
import requests, re, json
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36",
      "Accept": "text/html,application/xhtml+xml"}

portals = ["uscareers-nyu", "nymccareers-touro", "careers-mjhs"]

for portal in portals:
    print(f"\n===== {portal} =====")
    # 1) search page — list of jobs
    try:
        s = requests.get(f"https://{portal}.icims.com/jobs/search?ss=1&in_iframe=1&pr=0", headers=UA, timeout=15)
        html = s.text
        # job links look like /jobs/{id}/{slug}/job
        links = re.findall(r'/jobs/(\d+)/([a-z0-9%\-]+)/job', html, re.I)
        uniq = list(dict.fromkeys(links))
        # total count often in the page
        m = re.search(r'([\d,]+)\s*(?:Results|Jobs|Openings|Positions)', html, re.I)
        print(f"  search: HTTP {s.status_code}  {len(html)} bytes  job-links={len(uniq)}  total~={m.group(1) if m else '?'}")
        if uniq:
            print(f"    sample ids: {[i for i,_ in uniq[:5]]}")
    except Exception as e:
        print(f"  search ERR {type(e).__name__}: {e}"); uniq = []

    # 2) a job detail page — check for JSON-LD JobPosting
    if uniq:
        jid, slug = uniq[0]
        try:
            d = requests.get(f"https://{portal}.icims.com/jobs/{jid}/{slug}/job?in_iframe=1", headers=UA, timeout=15)
            blocks = re.findall(r'<script[^>]+application/ld\+json[^>]*>(.*?)</script>', d.text, re.S | re.I)
            found = None
            for b in blocks:
                try:
                    obj = json.loads(b.strip())
                    items = obj if isinstance(obj, list) else [obj]
                    for it in items:
                        if it.get("@type") == "JobPosting":
                            found = it; break
                except Exception:
                    continue
                if found: break
            if found:
                loc = (found.get("jobLocation") or {})
                addr = (loc.get("address") if isinstance(loc, dict) else {}) or {}
                pay = found.get("baseSalary") or {}
                desc = re.sub(r"<[^>]+>", " ", found.get("description", ""))
                print(f"  JSON-LD JobPosting FOUND:")
                print(f"    title: {found.get('title')}")
                print(f"    datePosted: {found.get('datePosted')}  validThrough: {found.get('validThrough')}")
                print(f"    hiringOrg: {(found.get('hiringOrganization') or {}).get('name')}")
                print(f"    location: {addr.get('addressLocality')}, {addr.get('addressRegion')}")
                print(f"    baseSalary: {pay.get('value') if pay else None}")
                print(f"    descLen: {len(desc)}")
            else:
                print(f"  job page HTTP {d.status_code}, {len(d.text)} bytes — NO JSON-LD JobPosting ({len(blocks)} ld+json blocks)")
        except Exception as e:
            print(f"  job page ERR {type(e).__name__}: {e}")
