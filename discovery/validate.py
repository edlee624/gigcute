#!/usr/bin/env python3
"""
Validate candidate ATS boards against their live public APIs.
Keeps only boards that return >0 jobs. Runs entirely locally — never touches
Supabase.

Input : one or more files of `platform,identifier` lines (from parse_dorks.py,
        or hand-written; identifier = slug, or tenant|dc|site for workday).
Output: appends winners to confirmed.csv ; records everything tried in tested.txt
        (so re-runs skip what's already been checked).

Usage:
  python validate.py candidates.csv [more.csv ...]

Supported auto-validate platforms: greenhouse, lever, ashby, workday,
smartrecruiters, workable. (taleo/icims are HTML/portal-gated — validate by hand.)
"""
import sys, os, csv, requests
from concurrent.futures import ThreadPoolExecutor, as_completed

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIRMED = os.path.join(HERE, "confirmed.csv")
TESTED = os.path.join(HERE, "tested.txt")
UA = {"User-Agent": "Mozilla/5.0 (gigcute-discovery)"}
WD_BODY = {"appliedFacets": {}, "limit": 1, "offset": 0, "searchText": ""}

# Supabase (public read-only anon key — safe to embed; RLS blocks writes).
SB_URL = "https://ztvirfxxyvvcrxcjstzi.supabase.co"
SB_ANON = "sb_publishable_G-5zb-7ncuxeOs_jMrjOOw_RDwQsHnc"

def existing_job_sources():
    """(platform, slug) already seeded in Supabase, so we don't re-test them."""
    try:
        r = requests.get(f"{SB_URL}/rest/v1/job_sources?select=platform,slug",
                         headers={"apikey": SB_ANON, "authorization": f"Bearer {SB_ANON}"}, timeout=20)
        return {(x["platform"], x["slug"]) for x in r.json()}
    except Exception as e:
        print(f"  (warn: could not fetch existing job_sources: {e})")
        return set()

def source_slug(platform, ident):
    """The slug as it appears in job_sources (Workday stores only the tenant;
    Oracle Cloud stores the pod, with the site code in the `site` column)."""
    return ident.split("|", 1)[0] if platform in ("workday", "oraclecloud") else ident

def check(platform, ident):
    """Return job count (>0 = live board) or 0."""
    try:
        if platform == "greenhouse":
            r = requests.get(f"https://boards-api.greenhouse.io/v1/boards/{ident}/jobs", headers=UA, timeout=8)
            return len((r.json() or {}).get("jobs") or []) if r.ok else 0
        if platform == "lever":
            r = requests.get(f"https://api.lever.co/v0/postings/{ident}?mode=json", headers=UA, timeout=8)
            j = r.json() if r.ok else None
            return len(j) if isinstance(j, list) else 0
        if platform == "ashby":
            r = requests.get(f"https://api.ashbyhq.com/posting-api/job-board/{ident}", headers=UA, timeout=8)
            return len((r.json() or {}).get("jobs") or []) if r.ok else 0
        if platform == "workday":
            tenant, dc, site = ident.split("|")
            r = requests.post(f"https://{tenant}.{dc}.myworkdayjobs.com/wday/cxs/{tenant}/{site}/jobs",
                              headers={**UA, "Content-Type": "application/json"}, json=WD_BODY, timeout=12)
            return r.json().get("total", 0) if r.ok else 0
        if platform == "smartrecruiters":
            r = requests.get(f"https://api.smartrecruiters.com/v1/companies/{ident}/postings", headers=UA, timeout=8)
            return len((r.json() or {}).get("content") or []) if r.ok else 0
        if platform == "workable":
            r = requests.get(f"https://apply.workable.com/api/v1/widget/accounts/{ident}?details=true", headers=UA, timeout=8)
            return len((r.json() or {}).get("jobs") or []) if r.ok else 0
        if platform == "bamboohr":
            r = requests.get(f"https://{ident}.bamboohr.com/careers/list", headers=UA, timeout=8)
            return len((r.json() or {}).get("result") or []) if r.ok else 0
        if platform == "recruitee":
            r = requests.get(f"https://{ident}.recruitee.com/api/offers/", headers=UA, timeout=8)
            return len((r.json() or {}).get("offers") or []) if r.ok else 0
        if platform == "oraclecloud":
            pod, site = ident.split("|")
            # TotalJobsCount is the board size; requisitionList needs the expand to populate.
            r = requests.get(f"https://{pod}.oraclecloud.com/hcmRestApi/resources/latest/recruitingCEJobRequisitions",
                             params={"onlyData": "true", "expand": "requisitionList.secondaryLocations",
                                     "finder": f"findReqs;siteNumber={site},limit=1,sortBy=POSTING_DATES_DESC"},
                             headers=UA, timeout=12)
            if not r.ok:
                return 0
            items = (r.json() or {}).get("items") or []
            if not items:
                return 0
            total = items[0].get("TotalJobsCount")
            return int(total) if total else len(items[0].get("requisitionList") or [])
    except Exception:
        return 0
    return 0

def read_lines(path):
    """Read a text file regardless of how Windows encoded it (utf-8/16/BOM)."""
    for enc in ("utf-8-sig", "utf-16", "latin-1"):
        try:
            with open(path, encoding=enc) as f:
                return f.read().splitlines()
        except (UnicodeError, UnicodeDecodeError):
            continue
    with open(path, encoding="utf-8", errors="ignore") as f:
        return f.read().splitlines()

def load_lines(path):
    return set(l.strip() for l in read_lines(path)) if os.path.exists(path) else set()

def main():
    if len(sys.argv) < 2:
        print("usage: python validate.py candidates.csv [more.csv ...]"); sys.exit(1)
    cands = []
    for path in sys.argv[1:]:
        for line in read_lines(path):
            line = line.strip()
            if line and "," in line and not line.startswith("#"):
                plat, ident = line.split(",", 1)
                cands.append((plat.strip().lower(), ident.strip()))
    cands = list(dict.fromkeys(cands))  # dedupe, keep order

    tested = load_lines(TESTED)
    confirmed_keys = set()
    if os.path.exists(CONFIRMED):
        for row in csv.reader(open(CONFIRMED, encoding="utf-8")):
            if len(row) >= 2:
                confirmed_keys.add(f"{row[0]}|{row[1]}")
    existing = existing_job_sources()
    print(f"already in job_sources: {len(existing)}")

    todo = [(p, i) for p, i in cands
            if f"{p}|{i}" not in tested and f"{p}|{i}" not in confirmed_keys
            and (p, source_slug(p, i)) not in existing]
    print(f"{len(cands)} candidates -> {len(todo)} new to test")

    found = []
    with ThreadPoolExecutor(max_workers=25) as ex:
        futs = {ex.submit(check, p, i): (p, i) for p, i in todo}
        for fut in as_completed(futs):
            p, i = futs[fut]
            n = fut.result()
            if n and n > 0:
                found.append((p, i, n))

    with open(TESTED, "a", encoding="utf-8") as t:
        for p, i in todo:
            t.write(f"{p}|{i}\n")
    with open(CONFIRMED, "a", encoding="utf-8", newline="") as c:
        w = csv.writer(c)
        for p, i, n in sorted(found):
            w.writerow([p, i, n])

    by_plat = {}
    for p, _, _ in found:
        by_plat[p] = by_plat.get(p, 0) + 1
    print(f"confirmed {len(found)} new live boards  {by_plat}")

if __name__ == "__main__":
    main()
