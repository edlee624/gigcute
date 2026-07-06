#!/usr/bin/env python3
"""Turn confirmed.csv into chunked, loadable job_sources INSERT migrations.
Only supported platforms; workday splits tenant|dc|site; slug used as company name."""
import csv, os
HERE = os.path.dirname(os.path.abspath(__file__))
MIGR = os.path.abspath(os.path.join(HERE, "..", "supabase", "migrations"))
SUPPORTED = {"greenhouse", "lever", "ashby", "workday"}
CHUNK = 1500
START_NUM = 41  # migration numbering start (0041_...)

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
    rows.append((plat, slug.replace("'", "''"), slug.replace("'", "''"), dc, site))

def esc(v):
    return f"'{v}'" if v else "null"

chunks = [rows[i:i+CHUNK] for i in range(0, len(rows), CHUNK)]
files = []
for idx, chunk in enumerate(chunks):
    num = START_NUM + idx
    path = os.path.join(MIGR, f"{num:04d}_bulk_cc_{idx+1}.sql")
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"-- Bulk CC-harvested company boards, part {idx+1}/{len(chunks)} ({len(chunk)} rows).\n")
        f.write("insert into public.job_sources (platform, slug, company_name, datacenter, site) values\n")
        vals = [f" ('{p}','{s}','{co}',{esc(dc)},{esc(site)})" for p, s, co, dc, site in chunk]
        f.write(",\n".join(vals))
        f.write("\non conflict (platform, slug) do nothing;\n")
    files.append(os.path.basename(path))

print(f"total supported unique rows: {len(rows)}")
byp = {}
for p, *_ in rows:
    byp[p] = byp.get(p, 0) + 1
print("by platform:", byp)
print(f"wrote {len(files)} migration files:", ", ".join(files))
