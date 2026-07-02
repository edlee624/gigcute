# GigCute — ATS Discovery Playbook

**Purpose of this session:** find and validate employer **ATS job boards**, then load
their identifiers into the Supabase `job_sources` table. That's it. This session is
*dedicated to discovery* — it does **not** touch the running app or the ingestion job.

> If you're a fresh Claude Code session on a new machine: read this whole file first,
> then follow **The Loop** below. Everything runs locally in Python; the only thing that
> reaches Supabase is a final SQL paste (or CSV import) that you (the human) do by hand.

---

## 1. How the whole system fits together

```
  THIS SESSION (local, any machine)              SUPABASE (untouched, already running)
  ─────────────────────────────────              ────────────────────────────────────
  dorks → parse → validate → flat files   ──►     job_sources  (table of boards to pull)
  (Python only, hits ATS vendor APIs)                   │
                                                        ▼
                                                  ingest-jobs edge function + cron
                                                  (pulls jobs, filters, writes `jobs`)
                                                        │
                                                        ▼
                                                  the GigCute job board (the app)
```

- **Discovery (this session)** only finds live boards. It never pulls jobs, never writes
  to `jobs`, never redeploys anything.
- The **edge function** (already deployed, runs every 10 min) reads `job_sources` and does
  all the ingestion. When you add rows to `job_sources`, it picks them up automatically on
  its next rotation — **no redeploy needed for pure slug additions.**
- The ingestion applies the fit filter (senior analytics/consulting/PM/transformation,
  ≥ $100k, posted ≤ 7 days). **Discovery does NOT filter by fit** — we just want boards
  that are *live* (return > 0 jobs). The edge function decides what's relevant.

## 2. Goal

Grow `job_sources` toward ~10k **direct company ATS boards**, prioritizing **enterprise**
platforms (that's where senior $100k+ analytics/consulting/PM roles live).

**Direct company boards ONLY.** Never add aggregators (Indeed, LinkedIn, ZipRecruiter,
Glassdoor, Google Jobs, Adzuna, Arbeitnow, SimplyHired, Monster). The test: does one
endpoint return *one company's* own jobs (keep) or *many companies'* jobs (reject)?

## 3. Current state (as of 2026-07-02)

`job_sources` ≈ 1,000 companies live:

| platform | companies | status |
|---|---|---|
| greenhouse | ~478 | ingesting |
| ashby | ~389 | ingesting |
| lever | ~133 | ingesting |
| workday | 24 | built; seed migration `0030_workday.sql` pending deploy |

Expansion priority (enterprise first): **Workday → SmartRecruiters → Taleo → iCIMS.**
SMB/EU platforms (Workable, BambooHR, Personio, Recruitee) are low priority for this
profile — small companies rarely post the senior $100k roles the filter wants.

## 4. The ATS platforms & their public endpoints (all probed live)

| platform | validate endpoint | identifier | notes |
|---|---|---|---|
| greenhouse | `GET boards-api.greenhouse.io/v1/boards/{slug}/jobs?content=true` | slug | clean JSON, full descriptions |
| lever | `GET api.lever.co/v0/postings/{slug}?mode=json` | slug | clean JSON array |
| ashby | `GET api.ashbyhq.com/posting-api/job-board/{slug}?includeCompensation=true` | slug | clean JSON |
| **workday** | `POST {tenant}.{dc}.myworkdayjobs.com/wday/cxs/{tenant}/{site}/jobs` body `{"appliedFacets":{},"limit":20,"offset":0,"searchText":""}` | tenant\|dc\|site | listing + per-job detail GET on `externalPath`; `dc` = wd1/wd3/wd5/wd12/wd501… |
| smartrecruiters | `GET api.smartrecruiters.com/v1/companies/{slug}/postings` | slug | clean JSON `.content` |
| workable | `GET apply.workable.com/api/v1/widget/accounts/{slug}?details=true` | slug | clean JSON `.jobs` |
| taleo | `POST {tenant}.taleo.net/careersection/rest/jobboard/searchjobs?lang=en&portal={portalId}` | tenant | JSON, but needs per-tenant portal id + search payload — validate by hand |
| icims | `{portal}.icims.com/jobs/search?in_iframe=1` | portal | HTML only (no JSON) — scrape, fragile |

`validate.py` auto-checks greenhouse/lever/ashby/workday/smartrecruiters/workable.
Taleo and iCIMS need manual handling (documented above).

## 5. Discovery method — Google dorks

`site:{ats-domain} "{job title}"` surfaces real live board URLs. Bias the titles toward
the target profile so you find relevant employers.

**Domains to dork:**
```
boards.greenhouse.io      job-boards.greenhouse.io
jobs.lever.co             jobs.ashbyhq.com
myworkdayjobs.com         jobs.smartrecruiters.com
apply.workable.com        taleo.net             icims.com
```
**Titles (the fit):**
```
"product manager"   "senior product manager"   "business analyst"
"customer experience"   "implementation consultant"   "management consultant"
"transformation"   "analytics manager"   "director analytics"   "vp analytics"
```
Run these in a browser (or ask this Claude session to run web searches), copy the result
URLs into a text file (one per line). ~10 results per query in a browser; a paid search
API (SerpAPI/Bing, 100/query paginated) or Common Crawl is how you'd scale to thousands.

## 6. The Loop

```
1. Dork:      run `site:{ats} "{title}"` searches; paste result URLs into  urls.txt
2. Parse:     python parse_dorks.py urls.txt >> candidates.csv
3. Validate:  python validate.py candidates.csv        # appends confirmed.csv, skips already-tested
4. Generate:  python make_sql.py                        # confirmed.csv -> job_sources_insert.sql
5. Upload:    paste job_sources_insert.sql into the Supabase SQL editor and run
```
That's it — the edge function ingests the new boards on its next rotation. Repeat forever.

You can also hand-write candidates: `candidates.csv` is just `platform,identifier` lines,
e.g. `greenhouse,stripe` or `workday,visa|wd5|Visa`.

## 7. Flat files (all local, git-ignored)

- `candidates.csv` — `platform,identifier` to test (from parse_dorks or by hand)
- `tested.txt` — every `platform|identifier` ever tried (re-runs skip these)
- `confirmed.csv` — winners: `platform,identifier,jobcount`
- `job_sources_insert.sql` — generated upload

## 8. Uploading to Supabase (pick one; never put the service_role key in a script)

- **A. SQL paste (default):** `make_sql.py` → open `job_sources_insert.sql` → paste into
  Supabase **SQL editor** → run. Idempotent (`on conflict do nothing`).
- **B. CSV import:** produce a CSV with columns `platform,slug,company_name,datacenter,site`
  → Supabase **Table Editor → Import data from CSV**. No SQL.

`job_sources` schema: `platform, slug, company_name, active (default true), datacenter, site`.
Unique on `(platform, slug)`. `datacenter`/`site` are only used by Workday.

Supabase project: `https://ztvirfxxyvvcrxcjstzi.supabase.co`
Anon key (public, read-only — fine to use for read checks): `sb_publishable_G-5zb-7ncuxeOs_jMrjOOw_RDwQsHnc`
The anon key **cannot** write `job_sources` (RLS is read-only) — that's why uploads go
through the SQL editor / dashboard, which run privileged. Don't hardcode the service_role key.

## 9. Guardrails

- Direct company boards only — no aggregators.
- Only keep boards returning > 0 jobs.
- Be polite to the ATS APIs: keep a User-Agent, concurrency ≤ ~30, reuse `tested.txt` so
  you never re-probe the same board.
- Never commit secrets. `confirmed.csv` / `tested.txt` are git-ignored (they're data, not code).

## 10. Files in this folder

- `DISCOVERY.md` — this playbook
- `parse_dorks.py` — URLs → `platform,identifier`
- `validate.py` — validate candidates → `confirmed.csv`
- `make_sql.py` — `confirmed.csv` → `job_sources_insert.sql`
- `.gitignore` — keeps the data flat-files local
