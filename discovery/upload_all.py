#!/usr/bin/env python3
"""Upload all confirmed boards to job_sources live via the Supabase Management API
(chunked; on conflict do nothing). Token read from %TEMP%/sbtok.txt."""
import csv, os, requests

HERE = os.path.dirname(os.path.abspath(__file__))
REF = "ztvirfxxyvvcrxcjstzi"
URI = f"https://api.supabase.com/v1/projects/{REF}/database/query"
TOK = open(os.path.join(os.environ.get("TEMP", "/tmp"), "sbtok.txt"), encoding="utf-8").read().strip()
HDR = {"Authorization": f"Bearer {TOK}"}
SUPPORTED = {"greenhouse", "lever", "ashby", "workday"}
CHUNK = 500

def q(sql):
    return requests.post(URI, headers=HDR, json={"query": sql}, timeout=90)

def esc(v):
    return "'" + v.replace("'", "''") + "'" if v else "null"

rows, seen = [], set()
for r in csv.reader(open(os.path.join(HERE, "confirmed.csv"), encoding="utf-8")):
    if len(r) < 2:
        continue
    plat, ident = r[0].strip(), r[1].strip()
    if plat not in SUPPORTED:
        continue
    if plat == "workday":
        parts = ident.split("|")
        if len(parts) != 3:
            continue
        slug, dc, site = parts
    else:
        slug, dc, site = ident, None, None
    key = (plat, slug)
    if key in seen:
        continue
    seen.add(key)
    rows.append((plat, slug, dc, site))

ok = 0
for i in range(0, len(rows), CHUNK):
    chunk = rows[i:i+CHUNK]
    vals = ",".join(
        f"('{p}',{esc(s)},{esc(s)},{esc(dc)},{esc(st)})" for p, s, dc, st in chunk
    )
    sql = f"insert into public.job_sources (platform,slug,company_name,datacenter,site) values {vals} on conflict (platform,slug) do nothing;"
    r = q(sql)
    if r.ok:
        ok += len(chunk)
    else:
        print(f"  chunk {i//CHUNK}: {r.status_code} {r.text[:140]}")

print(f"pushed {ok}/{len(rows)} rows (on conflict skips existing)")
tot = q("select count(*) c from public.job_sources").json()
print("job_sources total now:", tot[0]["c"] if tot else "?")
byp = q("select platform, count(*) c from public.job_sources group by 1 order by 2 desc").json()
for x in byp:
    print(f"  {x['platform']}: {x['c']}")
