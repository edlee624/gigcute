#!/usr/bin/env python3
"""
Local backfill: ingest jobs for every job_sources company that hasn't been swept
yet (last_ingested_at IS NULL). Ports the edge function's broad-mode logic
(14-day intake, all roles/salaries), upserts into public.jobs via the Supabase
Management API (postgres role) using the PAT in %TEMP%/sbtok.txt.

No 546 limit here, so it processes everything concurrently — the whole backlog
in one run instead of ~2 days of cron. Safe to re-run (upsert on source+external_id).

Usage: python backfill.py            (all pending)
       python backfill.py 500        (first 500 pending — for a test run)
"""
import os, sys, re, csv, time, json, requests
from datetime import datetime, timezone
from concurrent.futures import ThreadPoolExecutor, as_completed

SB = "https://ztvirfxxyvvcrxcjstzi.supabase.co"
ANON = "sb_publishable_G-5zb-7ncuxeOs_jMrjOOw_RDwQsHnc"
REF = "ztvirfxxyvvcrxcjstzi"
MGMT = f"https://api.supabase.com/v1/projects/{REF}/database/query"
TOK = open(os.path.join(os.environ.get("TEMP", "/tmp"), "sbtok.txt"), encoding="utf-8").read().strip()
UA = {"User-Agent": "Mozilla/5.0 (gigcute-backfill)"}
WDH = {**UA, "content-type": "application/json", "accept": "application/json"}
MAX_AGE_DAYS = 14
DESC_CAP = 16000
NOW = time.time()
WORKERS = 24
WD_DETAIL_CAP = 40

# ---- helpers (ported from the edge function) -------------------------------
def dec(s):
    if not s: return ""
    return (s.replace("&#x27;", "'").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
             .replace("&nbsp;", " ").replace("&quot;", '"').replace("&#39;", "'")
             .replace("&rsquo;", "'").replace("&mdash;", "—").replace("&ndash;", "–"))
def htmltext(s):
    if not s: return ""
    t = dec(s)
    if "<" in t:
        t = re.sub(r"</(p|div|li|br|h[1-6]|ul|ol|tr)>", "\n", t, flags=re.I)
        t = re.sub(r"<li[^>]*>", "• ", t, flags=re.I)
        t = re.sub(r"<[^>]+>", " ", t)
        t = dec(t)
    return re.sub(r"[ \t]+", " ", re.sub(r"\n{3,}", "\n\n", t)).strip()
SAL_RE = re.compile(r"\$\s?(\d{1,3}(?:,\d{3})+|\d{2,3}\s?[kK])\b")
def salary(txt):
    ns = []
    for m in SAL_RE.finditer(txt or ""):
        raw = m.group(1).replace(",", "").replace(" ", "").lower()
        v = int(raw[:-1]) * 1000 if raw.endswith("k") else int(raw)
        if 30000 <= v <= 1000000: ns.append(v)
    return (min(ns), max(ns)) if ns else (None, None)
def recent(iso):
    if not iso: return False
    try:
        s = str(iso).replace("Z", "+00:00")
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None: dt = dt.replace(tzinfo=timezone.utc)
        return (NOW - dt.timestamp()) <= MAX_AGE_DAYS * 86400
    except Exception:
        return False
def wd_maybe_recent(p):
    if not p: return True
    s = str(p).lower()
    if "today" in s or "yesterday" in s: return True
    m = re.search(r"(\d+)\s*\+?\s*day", s)
    return int(m.group(1)) <= MAX_AGE_DAYS if m else True
def cap(s): return (s[:DESC_CAP] + "…") if s and len(s) > DESC_CAP else s

def row(**k):
    k.setdefault("tags", [])
    return k

# ---- source fetchers (broad mode: keep all roles/salaries, recent + url) ----
def gh(slug, name):
    r = requests.get(f"https://boards-api.greenhouse.io/v1/boards/{slug}/jobs?content=true", headers=UA, timeout=15)
    if not r.ok: return []
    out = []
    for j in (r.json().get("jobs") or []):
        d = htmltext(j.get("content")); a, b = salary(d); posted = j.get("updated_at")
        url = j.get("absolute_url")
        if url and recent(posted):
            deps = [x.get("name") for x in (j.get("departments") or []) if x.get("name")]
            out.append(row(source="greenhouse", external_id=f"gh:{slug}:{j.get('id')}", title=j.get("title") or "Untitled",
                company=name or slug, location=(j.get("location") or {}).get("name"),
                remote=bool(re.search(r"remote", f"{j.get('title','')} {(j.get('location') or {}).get('name','')}", re.I)),
                employment_type=None, category=deps[0] if deps else None, salary_min=a, salary_max=b,
                salary_currency="USD", url=url, description=cap(d), tags=deps[:4], posted_at=posted))
    return out
def lever(slug, name):
    r = requests.get(f"https://api.lever.co/v0/postings/{slug}?mode=json", headers=UA, timeout=15)
    if not r.ok: return []
    arr = r.json()
    out = []
    for j in (arr if isinstance(arr, list) else []):
        d = j.get("descriptionPlain") or htmltext(j.get("description")); a, b = salary(d)
        cat = j.get("categories") or {}
        posted = datetime.fromtimestamp(j["createdAt"]/1000, timezone.utc).isoformat() if j.get("createdAt") else None
        url = j.get("hostedUrl")
        if url and recent(posted):
            out.append(row(source="lever", external_id=f"lever:{slug}:{j.get('id')}", title=j.get("text") or "Untitled",
                company=name or slug, location=cat.get("location"),
                remote=(j.get("workplaceType") == "remote"), employment_type=cat.get("commitment"),
                category=cat.get("team") or cat.get("department"), salary_min=a, salary_max=b, salary_currency="USD",
                url=url, description=cap(d), tags=[x for x in [cat.get("department"), cat.get("team")] if x][:4], posted_at=posted))
    return out
def ashby(slug, name):
    r = requests.get(f"https://api.ashbyhq.com/posting-api/job-board/{slug}?includeCompensation=true", headers=UA, timeout=15)
    if not r.ok: return []
    out = []
    for j in (r.json().get("jobs") or []):
        d = j.get("descriptionPlain") or htmltext(j.get("descriptionHtml"))
        a, b = salary((j.get("compensation") or {}).get("compensationTierSummary") or d)
        posted = j.get("publishedAt"); url = j.get("jobUrl") or j.get("applyUrl")
        if url and recent(posted):
            out.append(row(source="ashby", external_id=f"ashby:{slug}:{j.get('id')}", title=j.get("title") or "Untitled",
                company=name or slug, location=j.get("location"), remote=bool(j.get("isRemote")),
                employment_type=j.get("employmentType"), category=j.get("department") or j.get("team"),
                salary_min=a, salary_max=b, salary_currency="USD", url=url, description=cap(d),
                tags=[x for x in [j.get("department"), j.get("team")] if x][:4], posted_at=posted))
    return out
def workday(tenant, name, dc, site):
    if not dc or not site: return []
    base = f"https://{tenant}.{dc}.myworkdayjobs.com/wday/cxs/{tenant}/{site}"
    out, seen, details = [], set(), 0
    for off in (0, 20):
        try:
            r = requests.post(f"{base}/jobs", headers=WDH, json={"appliedFacets": {}, "limit": 20, "offset": off, "searchText": ""}, timeout=15)
        except Exception:
            break
        if not r.ok: break
        posts = r.json().get("jobPostings", [])
        if not posts: break
        for p in posts:
            if details >= WD_DETAIL_CAP: break
            if not wd_maybe_recent(p.get("postedOn")): continue
            ep = p.get("externalPath")
            if not ep or ep in seen: continue
            seen.add(ep); details += 1
            try:
                info = requests.get(f"{base}{ep}", headers=WDH, timeout=15).json().get("jobPostingInfo", {})
            except Exception:
                continue
            d = htmltext(info.get("jobDescription")); a, b = salary(d); posted = info.get("startDate")
            loc = info.get("location") or p.get("locationsText")
            url = info.get("externalUrl") or f"https://{tenant}.{dc}.myworkdayjobs.com/{site}{ep}"
            if url and recent(posted):
                out.append(row(source="workday", external_id=f"wd:{tenant}:{info.get('id') or info.get('jobReqId') or ep}",
                    title=info.get("title") or p.get("title") or "Untitled", company=name or tenant, location=loc,
                    remote=bool(re.search(r"remote", f"{info.get('remoteType','')} {loc or ''}", re.I)),
                    employment_type=info.get("timeType"), category=None, salary_min=a, salary_max=b,
                    salary_currency="USD", url=url, description=cap(d), tags=[], posted_at=posted))
        if len(posts) < 20 or details >= WD_DETAIL_CAP: break
    return out

def fetch(rec):
    p = rec["platform"]
    try:
        if p == "greenhouse": return rec, gh(rec["slug"], rec["company_name"])
        if p == "lever":      return rec, lever(rec["slug"], rec["company_name"])
        if p == "ashby":      return rec, ashby(rec["slug"], rec["company_name"])
        if p == "workday":    return rec, workday(rec["slug"], rec["company_name"], rec["datacenter"], rec["site"])
    except Exception:
        return rec, []
    return rec, []

# ---- Supabase writes via Management API (postgres role) ---------------------
def q(sql):
    return requests.post(MGMT, headers={"Authorization": f"Bearer {TOK}"}, json={"query": sql}, timeout=120)
def sql_str(v):
    if v is None: return "null"
    return "'" + str(v).replace("'", "''") + "'"
def sql_arr(v):
    if not v: return "'{}'"
    inner = ",".join('"' + str(x).replace('"', '\\"').replace("'", "''") + '"' for x in v)
    return "'{" + inner + "}'"
def sql_num(v): return str(v) if v is not None else "null"
def sql_bool(v): return "true" if v else "false"

COLS = "source,external_id,title,company,location,remote,employment_type,category,salary_min,salary_max,salary_currency,url,description,tags,posted_at,is_active"
def upsert(rows):
    if not rows: return 0
    n = 0
    for i in range(0, len(rows), 25):
        chunk = rows[i:i+25]
        vals = []
        for r in chunk:
            vals.append("(" + ",".join([
                sql_str(r["source"]), sql_str(r["external_id"]), sql_str(r["title"]), sql_str(r["company"]),
                sql_str(r["location"]), sql_bool(r["remote"]), sql_str(r["employment_type"]), sql_str(r["category"]),
                sql_num(r["salary_min"]), sql_num(r["salary_max"]), sql_str(r["salary_currency"]), sql_str(r["url"]),
                sql_str(r["description"]), sql_arr(r["tags"]), sql_str(r["posted_at"]), "true"]) + ")")
        sql = (f"insert into public.jobs ({COLS}) values " + ",".join(vals) +
               " on conflict (source,external_id) do update set title=excluded.title, description=excluded.description, "
               "salary_min=excluded.salary_min, salary_max=excluded.salary_max, location=excluded.location, "
               "posted_at=excluded.posted_at, is_active=true;")
        r = q(sql)
        if r.ok: n += len(chunk)
        else: print(f"    upsert err {r.status_code}: {r.text[:100]}")
    return n
def mark(ids):
    if not ids: return
    lst = ",".join("'" + i + "'" for i in ids)
    q(f"update public.job_sources set last_ingested_at = now() where id in ({lst});")

# ---- main ------------------------------------------------------------------
def load_pending(limit=None):
    H = {"apikey": ANON, "authorization": f"Bearer {ANON}"}
    recs, offset, PAGE = [], 0, 1000
    while True:
        r = requests.get(f"{SB}/rest/v1/job_sources?select=id,platform,slug,company_name,datacenter,site&active=eq.true&last_ingested_at=is.null&order=id&limit={PAGE}&offset={offset}", headers=H, timeout=30)
        batch = r.json()
        if not batch: break
        recs += batch; offset += len(batch)
        if limit and len(recs) >= limit: return recs[:limit]
        if len(batch) < PAGE: break
    return recs

def main():
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else None
    pend = load_pending(limit)
    print(f"pending companies to backfill: {len(pend)}", flush=True)
    done = jobs = 0
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        futs = [ex.submit(fetch, r) for r in pend]
        for f in as_completed(futs):
            rec, rows = f.result()
            jobs += upsert(rows)
            mark([rec["id"]])
            done += 1
            if done % 100 == 0:
                print(f"  {done}/{len(pend)} companies, {jobs} jobs upserted", flush=True)
    print(f"DONE: {done} companies swept, {jobs} jobs upserted", flush=True)

if __name__ == "__main__":
    main()
