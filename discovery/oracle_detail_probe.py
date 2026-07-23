#!/usr/bin/env python3
"""Nail down the Oracle Cloud Recruiting DETAIL endpoint (full description).
The list gives only ShortDescriptionStr; try finder-syntax variants to fetch the
full posting text before building the fetcher."""
import requests, json, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
UA = {"User-Agent": "Mozilla/5.0 (gigcute-discovery)", "Accept": "application/json"}

BOARDS = [("ejgl.fa.ap1", "CX_1"), ("ebuu.fa.ap1", "CX"), ("edox.fa.ap1", "CX_3001")]

def list_one(host, site):
    url = (f"https://{host}.oraclecloud.com/hcmRestApi/resources/latest/recruitingCEJobRequisitions"
           f"?onlyData=true&expand=requisitionList.secondaryLocations,requisitionList.workLocation"
           f"&finder=findReqs;siteNumber={site},limit=1,sortBy=POSTING_DATES_DESC")
    r = requests.get(url, headers=UA, timeout=15)
    if not r.ok: return None
    items = r.json().get("items") or []
    rl = items[0].get("requisitionList") if items else []
    return rl[0] if rl else None

def try_detail(host, site, reqid):
    base = f"https://{host}.oraclecloud.com/hcmRestApi/resources/latest/recruitingCEJobRequisitionDetails"
    variants = [
        f'{base}?expand=all&onlyData=true&finder=ByReqId;Id="{reqid}",siteNumber={site}',
        f'{base}?expand=all&onlyData=true&finder=ByReqId;Id={reqid},siteNumber={site}',
        f'{base}?onlyData=true&expand=all&finder=ByReqId;Id="{reqid}",siteNumber="{site}"',
    ]
    for i, url in enumerate(variants):
        try:
            r = requests.get(url, headers=UA, timeout=15)
        except Exception as e:
            print(f"    variant {i}: ERR {type(e).__name__}"); continue
        if not r.ok:
            print(f"    variant {i}: HTTP {r.status_code}"); continue
        items = r.json().get("items") or []
        if not items:
            print(f"    variant {i}: 200 but 0 items"); continue
        d = items[0]
        dk = [k for k in d if 'escription' in k or 'ualification' in k or 'Url' in k]
        ext = d.get("ExternalDescriptionStr") or d.get("ExternalDescription") or ""
        print(f"    variant {i}: OK  keys={dk}")
        print(f"      ExternalDescriptionStr len={len(ext)}  Title={d.get('Title')!r}")
        for uk in ("ExternalUrl", "ApplyUrl", "ExternalPostingUrl"):
            if d.get(uk): print(f"      {uk}={d[uk][:70]}")
        return True
    return False

for host, site in BOARDS:
    print(f"\n== {host} / {site} ==")
    j = list_one(host, site)
    if not j:
        print("  no live job"); continue
    print(f"  list job Id={j.get('Id')!r}  Title={j.get('Title')!r}")
    try_detail(host, site, j.get("Id"))
