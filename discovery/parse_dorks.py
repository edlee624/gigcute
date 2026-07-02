#!/usr/bin/env python3
"""
Extract ATS identifiers from a file of URLs pasted from Google dorks.
Emits CSV lines: `platform,identifier`
  - identifier = slug for most platforms
  - identifier = tenant|datacenter|site  for Workday

Usage:
  python parse_dorks.py urls.txt [more.txt ...]
  -> appends new `platform,identifier` lines to candidates.csv (utf-8, deduped)

(Writes the file itself instead of relying on shell `>>`, which on PowerShell
produces UTF-16 that the other scripts can't read.)
"""
import sys, os, re

HERE = os.path.dirname(os.path.abspath(__file__))

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

def parse(url):
    u = url.strip()
    m = re.search(r'https?://(?:job-)?boards\.greenhouse\.io/(?:embed/job_app\?for=)?([a-z0-9_-]+)', u, re.I)
    if m: return ("greenhouse", m.group(1).lower())
    m = re.search(r'https?://jobs\.lever\.co/([a-z0-9_.-]+)', u, re.I)
    if m: return ("lever", m.group(1).lower())
    m = re.search(r'https?://jobs\.ashbyhq\.com/([a-z0-9_-]+)', u, re.I)
    if m: return ("ashby", m.group(1).lower())
    # Workday: {tenant}.{wdNN}.myworkdayjobs.com/[en-US/]{site}/...
    m = re.search(r'https?://([a-z0-9_-]+)\.(wd\d+)\.myworkdayjobs\.com/(?:[a-z]{2}-[A-Za-z]{2}/)?([A-Za-z0-9_-]+)', u)
    if m: return ("workday", f"{m.group(1).lower()}|{m.group(2).lower()}|{m.group(3)}")
    m = re.search(r'https?://jobs\.smartrecruiters\.com/([A-Za-z0-9_-]+)', u)
    if m: return ("smartrecruiters", m.group(1))
    m = re.search(r'https?://apply\.workable\.com/([a-z0-9_-]+)', u, re.I)
    if m: return ("workable", m.group(1).lower())
    m = re.search(r'https?://([a-z0-9_-]+)\.taleo\.net', u, re.I)
    if m: return ("taleo", m.group(1).lower())
    m = re.search(r'https?://([a-z0-9_-]+)\.icims\.com', u, re.I)
    if m: return ("icims", m.group(1).lower())
    m = re.search(r'https?://([a-z0-9_-]+)\.recruitee\.com', u, re.I)
    if m: return ("recruitee", m.group(1).lower())
    return None

def main():
    if len(sys.argv) < 2:
        print("usage: python parse_dorks.py urls.txt [more.txt ...]")
        sys.exit(1)
    out = os.path.join(HERE, "candidates.csv")
    existing = set()
    if os.path.exists(out):
        existing = {l.strip() for l in read_lines(out) if l.strip()}
    new = []
    for path in sys.argv[1:]:
        for line in read_lines(path):
            r = parse(line)
            if r:
                s = f"{r[0]},{r[1]}"
                if s not in existing:
                    existing.add(s)
                    new.append(s)
    with open(out, "a", encoding="utf-8") as f:
        for s in new:
            f.write(s + "\n")
    print(f"+{len(new)} new candidates -> {out}")
    for s in new:
        print("  " + s)

if __name__ == "__main__":
    main()
