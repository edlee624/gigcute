#!/usr/bin/env python3
"""Resolve the SuccessFactors RMK feed host for each company fingerprinted as
'successfactors'. The career site lives on a custom domain (careers.X.com,
jobs.X.com, X.jobs, ...), so we probe candidate hosts for a live /job-feed.xml and
keep the one that serves the most job items. Writes sf_hosts.csv (host,company,jobs).
"""
import csv, os, re, sys, requests
from concurrent.futures import ThreadPoolExecutor, as_completed

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "sf_hosts.csv")
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36", "Accept": "*/*"}

def root(domain):
    d = re.sub(r"^www\.", "", (domain or "").strip().lower())
    return d

def candidate_hosts(domain):
    d = root(domain)
    if not d:
        return []
    stem = d.split(".")[0]
    return [f"careers.{d}", f"jobs.{d}", f"career.{d}", f"{stem}.jobs",
            f"careers.{stem}.com", f"jobs.{stem}.com", d, f"www.{d}"]

def feed_jobs(host):
    """Return item count if host serves a SuccessFactors RMK feed, else -1."""
    try:
        r = requests.get(f"https://{host}/job-feed.xml", headers=UA, timeout=12)
    except Exception:
        return -1
    if not r.ok or "<item>" not in r.text:
        return -1
    # RMK feeds use the Google-jobs schema; guard against unrelated RSS.
    if "successfactors" not in r.text.lower() and "g:location" not in r.text and "rmk" not in r.text.lower():
        # still likely SF if it has g: namespace items; accept on item+link+g:id
        if "<g:id>" not in r.text:
            return -1
    return r.text.count("<item>")

def resolve(company, domain):
    for h in candidate_hosts(domain):
        n = feed_jobs(h)
        if n >= 0:
            return (h, company, n)
    return None

def main():
    src = os.path.join(HERE, "ats_fingerprint.csv")
    targets = [(r["company"], r["domain"]) for r in csv.DictReader(open(src, encoding="utf-8"))
               if r["ats"] == "successfactors"]
    print(f"resolving SF feed host for {len(targets)} companies...", flush=True)
    found = []
    with ThreadPoolExecutor(max_workers=16) as ex:
        futs = {ex.submit(resolve, c, d): c for c, d in targets}
        for f in as_completed(futs):
            r = f.result()
            if r:
                found.append(r)
                print(f"  OK {r[0]:34} {r[2]:5} jobs  ({r[1]})", flush=True)
    found.sort(key=lambda x: -x[2])
    with open(OUT, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        for host, company, n in found:
            w.writerow([host, company, n])
    miss = len(targets) - len(found)
    print(f"\nresolved {len(found)}/{len(targets)} feed hosts ({miss} unresolved) -> {OUT}", flush=True)

if __name__ == "__main__":
    main()
