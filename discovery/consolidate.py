#!/usr/bin/env python3
"""Merge migrations 0034-0045 into ONE consolidated file, deduped by (platform,slug)
with the first (nicer-named, lower-numbered) occurrence winning. Chunked INSERTs."""
import re, os, glob

HERE = os.path.dirname(os.path.abspath(__file__))
MIGR = os.path.abspath(os.path.join(HERE, "..", "supabase", "migrations"))
OUT = os.path.join(MIGR, "0046_all_discovered.sql")

ROW_RE = re.compile(
    r"\(\s*'([a-z]+)'\s*,\s*'((?:[^']|'')*)'\s*,\s*'((?:[^']|'')*)'\s*,\s*('(?:[^']|'')*'|null)\s*,\s*('(?:[^']|'')*'|null)\s*\)"
)

files = sorted(glob.glob(os.path.join(MIGR, "003[4-9]_*.sql")) +
               glob.glob(os.path.join(MIGR, "004[0-5]_*.sql")))
rows, seen = [], set()
for path in files:
    if os.path.basename(path).startswith("0046"):
        continue
    text = open(path, encoding="utf-8").read()
    for m in ROW_RE.finditer(text):
        plat, slug, name, dc, site = m.groups()
        key = (plat, slug)
        if key in seen:
            continue
        seen.add(key)
        rows.append((plat, slug, name, dc, site))

CHUNK = 1000
with open(OUT, "w", encoding="utf-8") as f:
    f.write("-- CONSOLIDATED: all boards discovered this session (batches 0034-0045), deduped.\n")
    f.write(f"-- {len(rows)} companies. Idempotent. Run this ONE file instead of 0034-0045.\n\n")
    for i in range(0, len(rows), CHUNK):
        chunk = rows[i:i+CHUNK]
        f.write("insert into public.job_sources (platform, slug, company_name, datacenter, site) values\n")
        f.write(",\n".join(f" ('{p}','{s}','{n}',{dc},{st})" for p, s, n, dc, st in chunk))
        f.write("\non conflict (platform, slug) do nothing;\n\n")

by = {}
for p, *_ in rows:
    by[p] = by.get(p, 0) + 1
print(f"consolidated {len(rows)} unique companies -> {OUT}")
print("by platform:", by)
