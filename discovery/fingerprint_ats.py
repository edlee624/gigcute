#!/usr/bin/env python3
"""
For the largest US companies (S&P 500), find each one's careers page and
fingerprint which ATS platform it runs on — so we can see which big employers
sit on platforms we DON'T already ingest (the coverage gap).

Pipeline per company:
  1. resolve a domain from the company name (Clearbit public autocomplete)
  2. fetch a few careers-page candidates + the homepage (follow redirects)
  3. fingerprint the ATS from the final URLs + page HTML (hostnames/markers)
  4. bucket: COVERED (one of our 9 platforms) vs GAP (SuccessFactors, Phenom,
     Eightfold, Taleo, iCIMS, Avature, Jobvite, ADP, UKG, custom, ...)

Writes ats_fingerprint.csv (ticker,company,domain,ats,bucket,evidence).
Read-only against the web; touches nothing in Supabase.
Run: python fingerprint_ats.py
"""
import csv, os, re, sys, time, json, requests
from urllib.parse import urljoin, urlparse
from concurrent.futures import ThreadPoolExecutor, as_completed
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "ats_fingerprint.csv")
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122 Safari/537.36",
      "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}
WORKERS = 20

# Platforms we already ingest (see ingest-jobs + job_sources).
COVERED = {"workday", "oraclecloud", "greenhouse", "lever", "ashby",
           "smartrecruiters", "workable", "bamboohr", "recruitee"}

# ATS fingerprints: ats-name -> list of regexes matched against final URLs + HTML.
# Order matters — first hit wins, so put the specific/embeddable ones first.
FINGERPRINTS = [
    ("workday",        [r"myworkdayjobs\.com", r"myworkdaysite\.com", r"\.wd\d+\.myworkday", r"/wday/"]),
    ("oraclecloud",    [r"oraclecloud\.com/hcm", r"/hcmUI/CandidateExperience", r"hcmRestApi"]),
    ("taleo",          [r"taleo\.net", r"tbe\.taleo", r"\.taleo\.com"]),
    ("greenhouse",     [r"boards\.greenhouse\.io", r"job-boards\.greenhouse\.io", r"greenhouse\.io/embed", r"grnh\.se"]),
    ("lever",          [r"jobs\.lever\.co", r"\.lever\.co"]),
    ("ashby",          [r"jobs\.ashbyhq\.com", r"ashbyhq\.com"]),
    ("smartrecruiters",[r"smartrecruiters\.com"]),
    ("workable",       [r"apply\.workable\.com", r"\.workable\.com"]),
    ("bamboohr",       [r"\.bamboohr\.com"]),
    ("recruitee",      [r"\.recruitee\.com"]),
    ("icims",          [r"\.icims\.com"]),
    ("successfactors", [r"successfactors\.com", r"\.sapsf\.com", r"jobs\.sap\.com", r"careers\d*\.sapsf", r"/sfcareer/"]),
    ("phenom",         [r"phenompeople\.com", r"\.phenom\.", r"phenomapp"]),
    ("eightfold",      [r"eightfold\.ai"]),
    ("avature",        [r"avature\.net"]),
    ("jobvite",        [r"jobvite\.com", r"jobs\.jobvite"]),
    ("brassring",      [r"brassring\.com", r"kenexa", r"sjobs\.brassring"]),
    ("ultipro_ukg",    [r"ultipro\.com", r"recruiting\.ukg", r"\.ukg\.com"]),
    ("adp",            [r"workforcenow\.adp\.com", r"myjobs\.adp"]),
    ("dayforce",       [r"dayforcehcm\.com", r"dayforce"]),
    ("paylocity",      [r"recruiting\.paylocity\.com"]),
    ("jazzhr",         [r"applytojob\.com", r"\.jazz\.co"]),
    ("breezy",         [r"\.breezy\.hr"]),
    ("teamtailor",     [r"\.teamtailor\.com"]),
    ("jobscore",       [r"jobscore\.com"]),
    ("gem",            [r"jobs\.gem\.com"]),
    ("rippling",       [r"ats\.rippling\.com"]),
    ("workforcenow",   [r"careers\.google\.com"]),  # google's own custom board (kept distinct)
]

STOP = re.compile(r"\b(inc|corp|corporation|co|company|companies|holdings|holding|group|"
                  r"plc|ltd|lp|llc|the|class|and)\b|[.,&']|\s*\(.*?\)", re.I)

def name_guess(name):
    """Heuristic domain from the company name (right surprisingly often)."""
    base = STOP.sub(" ", name)
    base = re.sub(r"\s+", "", base).lower()
    return f"{base}.com" if base else None

def _match_score(name, domain):
    root = domain.split(".")[0].lower()
    n = re.sub(r"[^a-z0-9]", "", name.lower())
    return 2 if root and root in n else (1 if root and n.startswith(root[:5]) else 0)

def wikidata_domain(name):
    """Official website (P856) from Wikidata — structured, accurate for the abbreviated
    names that defeat name-guessing (Abbott Laboratories->abbott.com, AMD->amd.com,
    Archer Daniels Midland->adm.com). Cleans corporate suffixes/'(Class A)' from the
    query and scans the top few entities for one that carries a website."""
    q = re.sub(r"\(class [abc]\)|\b(inc|corp|corporation|co|company|plc|ltd|holdings|the)\b|[.,]",
               " ", name, flags=re.I).strip()
    try:
        r = requests.get("https://www.wikidata.org/w/api.php", headers=UA, timeout=8, params={
            "action": "wbsearchentities", "search": q or name, "language": "en",
            "type": "item", "format": "json", "limit": 4})
        for hit in ((r.json() or {}).get("search") or []):
            r2 = requests.get("https://www.wikidata.org/w/api.php", headers=UA, timeout=8, params={
                "action": "wbgetclaims", "entity": hit["id"], "property": "P856", "format": "json"})
            claims = ((r2.json() or {}).get("claims") or {}).get("P856") or []
            for c in claims:
                try:
                    url = c["mainsnak"]["datavalue"]["value"]
                except (KeyError, TypeError):
                    continue
                host = urlparse(url).netloc.lower()
                host = host[4:] if host.startswith("www.") else host
                if host:
                    return host
    except Exception:
        return None
    return None

def resolve_domains(name):
    """Ordered candidate domains: Wikidata official site first (structured + accurate),
    then name-guess, then Clearbit (only when its root strongly matches the name —
    it returns blogs/unrelated sites like mega.nz for '3M' that cause false ATS hits)."""
    cands = []
    for d in (wikidata_domain(name), name_guess(name)):
        if d and d not in cands:
            cands.append(d)
    try:
        r = requests.get("https://autocomplete.clearbit.com/v1/companies/suggest",
                         params={"query": name}, headers=UA, timeout=8)
        if r.ok:
            for s in r.json():
                d = s.get("domain")
                if d and d not in cands and _match_score(name, d) >= 2:
                    cands.append(d)
    except Exception:
        pass
    return cands[:3]

def fetch(url):
    try:
        r = requests.get(url, headers=UA, timeout=12, allow_redirects=True)
        return r
    except Exception:
        return None

def classify_text(blob):
    for ats, pats in FINGERPRINTS:
        for p in pats:
            m = re.search(p, blob, re.I)
            if m:
                return ats, m.group(0)
    return None, None

LINK_RE = re.compile(r'href=["\']([^"\']+)["\']', re.I)
CAREER_HREF = re.compile(r'career|/jobs|/job/|/job\b|talent|join-?us|work-?with-?us|work-?here|life-?at', re.I)

def scan_response(r):
    """Fingerprint a response by its final URL then its HTML. Returns (ats, ev) or (None,None)."""
    final = str(r.url)
    ats, ev = classify_text(final)
    if ats:
        return ats, final
    return classify_text(r.text[:400000])

def follow_career_links(r):
    """From a homepage response, follow up to 3 links that look like careers/jobs
    and fingerprint each. Catches odd paths (/en/careers, /company/careers) and
    cross-domain ATS links (homepage -> boards.greenhouse.io/foo)."""
    base = str(r.url)
    seen, links = set(), []
    for href in LINK_RE.findall(r.text[:400000]):
        if CAREER_HREF.search(href):
            u = urljoin(base, href.split("#")[0])
            if u.startswith("http") and u not in seen:
                seen.add(u); links.append(u)
    for u in links[:3]:
        ats, ev = classify_text(u)               # the link URL itself may be the ATS
        if ats:
            return ats, u
        rr = fetch(u)
        if rr is not None and rr.ok:
            ats, ev = scan_response(rr)
            if ats:
                return ats, ev
    return None, None

def fingerprint(domains):
    """Return (ats, evidence, domain). Tries careers candidates + homepage across
    each candidate domain, follows careers links, scans final URLs + HTML."""
    if not domains:
        return "unresolved", "", ""
    careers_seen, careers_dom = False, ""
    for domain in domains:
        got_any = False
        for url in [f"https://{domain}/careers", f"https://careers.{domain}",
                    f"https://{domain}/jobs", f"https://jobs.{domain}",
                    f"https://{domain}/careers/jobs", f"https://{domain}"]:
            r = fetch(url)
            if r is None or not r.ok:
                continue
            got_any = True
            ats, ev = scan_response(r)
            if ats:
                return ats, ev, domain
            # homepage (or any resolved page): chase its careers/jobs links
            ats, ev = follow_career_links(r)
            if ats:
                return ats, ev, domain
            if "/careers" in url or "/jobs" in url or re.search(r"career|job", str(r.url), re.I):
                careers_seen, careers_dom = True, domain
        if got_any and not careers_dom:
            careers_dom = domain  # domain resolved, just no ATS identified
    return ("custom_unknown" if careers_seen else "no_careers_found"), "", careers_dom

def load_sp500():
    path = os.path.join(HERE, "sp500_raw.csv")
    rows = []
    if os.path.exists(path):
        for r in csv.DictReader(open(path, encoding="utf-8")):
            # datasets CSV header: Symbol,Security,GICS Sector,...
            sym = r.get("Symbol") or r.get("symbol") or ""
            name = r.get("Security") or r.get("Name") or r.get("security") or ""
            if name:
                rows.append((sym.strip(), name.strip()))
    return rows

UNDET = ("unresolved", "no_careers_found", "custom_unknown")

def work(rec):
    sym, name = rec
    domains = resolve_domains(name)
    ats, ev, dom = fingerprint(domains)
    bucket = "covered" if ats in COVERED else ("undetermined" if ats in UNDET else "gap")
    return (sym, name, dom or (domains[0] if domains else ""), ats, bucket, ev[:120])

def main():
    companies = load_sp500()
    if not companies:
        print("ERROR: sp500_raw.csv not found or empty — fetch the constituents list first.")
        sys.exit(1)
    print(f"fingerprinting {len(companies)} companies with {WORKERS} workers...", flush=True)
    results = []
    done = 0
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        futs = [ex.submit(work, c) for c in companies]
        for f in as_completed(futs):
            try:
                results.append(f.result())
            except Exception:
                pass
            done += 1
            if done % 50 == 0:
                print(f"  {done}/{len(companies)}", flush=True)

    with open(OUT, "w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["ticker", "company", "domain", "ats", "bucket", "evidence"])
        for row in sorted(results, key=lambda x: (x[4], x[3], x[1])):
            w.writerow(row)

    # summary
    from collections import Counter
    by_ats = Counter(r[3] for r in results)
    by_bucket = Counter(r[4] for r in results)
    print("\n=== ATS distribution ===")
    for ats, n in by_ats.most_common():
        tag = "COVERED" if ats in COVERED else ("gap" if by_bucket_key(ats) else "")
        print(f"  {ats:18} {n:4}  {'(covered)' if ats in COVERED else ''}")
    print("\n=== buckets ===")
    for b, n in by_bucket.most_common():
        print(f"  {b:16} {n}")
    print(f"\nwrote {OUT}")

def by_bucket_key(ats):
    return ats not in COVERED and ats not in ("unresolved", "no_careers_found", "custom_unknown")

if __name__ == "__main__":
    main()
