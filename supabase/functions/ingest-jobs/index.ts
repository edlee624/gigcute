// ============================================================================
// GigCute — ingest-jobs Edge Function
// Pulls job listings from public job APIs, normalizes them, and upserts into
// public.jobs (deduped by source + external_id). Meant to be called on a
// schedule (Supabase Cron / pg_cron). Deploy with JWT verification OFF and
// protect it with the CRON_SECRET header instead.
//
// Memory note: ATS feeds return full descriptions for MANY jobs, so each source
// upserts INCREMENTALLY (per company / per page) rather than accumulating all
// rows in memory — otherwise the worker hits its memory limit (error 546).
//
// Sources: direct company ATS boards only (Greenhouse / Lever / Ashby).
// Aggregators (Adzuna, Arbeitnow) removed — each source is one company's board.
//
// Env (Project Settings → Edge Functions → Secrets):
//   CRON_SECRET, ATS_BATCH (companies/run, default 20), JOB_TITLE_ANY,
//   JOB_SENIORITY_ANY, JOB_MIN_SALARY (default 100000; 0 = off),
//   JOB_MAX_AGE_DAYS (intake cap, default 7), JOB_RETENTION_DAYS (default 30)
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type JobRow = {
  source: string; external_id: string; title: string; company: string | null;
  location: string | null; remote: boolean; employment_type: string | null;
  category: string | null; salary_min: number | null; salary_max: number | null;
  salary_currency: string | null; url: string; description: string | null;
  tags: string[]; posted_at: string | null; is_active: boolean;
};
type Src = { slug: string; company_name?: string | null; datacenter?: string | null; site?: string | null };
type Report = { fetched: number; upserted: number; error?: string };

const DESC_CAP = 16000; // keep full ads but bound extreme outliers (memory)
const cap = (s: string | null): string | null => (s && s.length > DESC_CAP ? s.slice(0, DESC_CAP) + "…" : s);

function csvEnv(name: string, def: string): string[] {
  return (Deno.env.get(name) || def).split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
}
const TITLE_ANY = csvEnv("JOB_TITLE_ANY",
  "cx,analyt,product manager,implementation consultant,transformation,management consultant,ai consultant,business analyst,customer experience");
const SENIORITY_ANY = csvEnv("JOB_SENIORITY_ANY",
  "senior manager,manager,director,avp,vp,svp,vice president,head of");
const SENIORITY_RE = SENIORITY_ANY.map((s) => new RegExp(`\\b${s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`, "i"));
function fitsCriteria(title: string | null | undefined): boolean {
  const t = (title || "").toLowerCase();
  if (!t) return false;
  return TITLE_ANY.some((k) => t.includes(k)) && SENIORITY_RE.some((re) => re.test(t));
}
const JOB_MIN_SALARY = Math.max(0, parseInt(Deno.env.get("JOB_MIN_SALARY") || "100000", 10) || 0);
function meetsSalary(r: { salary_min: number | null; salary_max: number | null }): boolean {
  if (JOB_MIN_SALARY <= 0) return true;
  return (r.salary_max != null && r.salary_max >= JOB_MIN_SALARY) ||
         (r.salary_min != null && r.salary_min >= JOB_MIN_SALARY);
}
// Only ingest recently-posted jobs (default 7 days). A job with no/unparseable
// date is treated as too old (excluded) so the board stays fresh while testing.
const MAX_AGE_DAYS = Math.max(1, parseInt(Deno.env.get("JOB_MAX_AGE_DAYS") || "7", 10) || 7);
const RETENTION_DAYS = Math.max(1, parseInt(Deno.env.get("JOB_RETENTION_DAYS") || "30", 10) || 30);
function isRecent(iso: string | null): boolean {
  if (!iso) return false;
  const t = Date.parse(iso);
  if (isNaN(t)) return false;
  return (Date.now() - t) <= MAX_AGE_DAYS * 86400000;
}
function decodeEntities(s: string): string {
  return s
    .replace(/&#x([0-9a-f]+);/gi, (_m, n) => String.fromCharCode(parseInt(n, 16)))
    .replace(/&#(\d+);/g, (_m, n) => String.fromCharCode(+n))
    .replace(/&nbsp;/gi, " ")
    .replace(/&#39;|&rsquo;|&lsquo;|&apos;/gi, "'").replace(/&quot;|&ldquo;|&rdquo;/gi, '"')
    .replace(/&mdash;/gi, "—").replace(/&ndash;/gi, "–").replace(/&hellip;/gi, "…").replace(/&bull;/gi, "•")
    .replace(/&lt;/gi, "<").replace(/&gt;/gi, ">").replace(/&amp;/gi, "&");
}
function htmlToText(s: string | null | undefined): string | null {
  if (!s) return null;
  // Greenhouse (and some boards) entity-ENCODE their HTML (e.g. "&lt;p&gt;&amp;nbsp;"),
  // so decode ONCE to recover the real tags, strip the tags, then decode a second
  // time to catch entities that were double-encoded (e.g. "&amp;nbsp;").
  let t = decodeEntities(s);
  t = t.replace(/<\/(p|div|li|br|h[1-6]|ul|ol|tr)>/gi, "\n").replace(/<li[^>]*>/gi, "• ").replace(/<[^>]*>/g, " ");
  t = decodeEntities(t);
  return t.replace(/[ \t]+/g, " ").replace(/\n{3,}/g, "\n\n").trim();
}
function extractSalary(text: string | null | undefined): { min: number | null; max: number | null } {
  if (!text) return { min: null, max: null };
  const nums: number[] = [];
  const re = /\$\s?(\d{1,3}(?:,\d{3})+|\d{2,3}\s?[kK])\b/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    const raw = m[1].replace(/[,\s]/g, "").toLowerCase();
    const v = raw.endsWith("k") ? parseInt(raw) * 1000 : parseInt(raw);
    if (v >= 30000 && v <= 1000000) nums.push(v);
  }
  return nums.length ? { min: Math.min(...nums), max: Math.max(...nums) } : { min: null, max: null };
}

// deno-lint-ignore no-explicit-any
async function upsert(supabase: any, rows: JobRow[]): Promise<number> {
  let n = 0;
  for (let i = 0; i < rows.length; i += 200) {
    const chunk = rows.slice(i, i + 200);
    const { error } = await supabase.from("jobs").upsert(chunk, { onConflict: "source,external_id" });
    if (error) throw error;
    n += chunk.length;
  }
  return n;
}
// Bounded-concurrency runner; per-item errors are swallowed. No accumulation.
async function runLimit<T>(items: T[], limit: number, fn: (x: T) => Promise<void>): Promise<void> {
  let i = 0;
  const worker = async () => { while (i < items.length) { const it = items[i++]; try { await fn(it); } catch (_e) { /* skip */ } } };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
}

// ---- ATS sources — full descriptions, upserted per company (low memory) ------
// deno-lint-ignore no-explicit-any
async function fromGreenhouse(supabase: any, list: Src[]): Promise<Report> {
  let fetched = 0, upserted = 0;
  await runLimit(list, 4, async ({ slug, company_name }) => {
    const res = await fetch(`https://boards-api.greenhouse.io/v1/boards/${slug}/jobs?content=true`);
    if (!res.ok) return;
    const json = await res.json();
    const rows: JobRow[] = [];
    for (const j of (json?.jobs ?? [])) {
      const desc = htmlToText(j.content);
      const sal = extractSalary(desc);
      const row: JobRow = {
        source: "greenhouse", external_id: `gh:${slug}:${j.id}`, title: j.title ?? "Untitled",
        company: company_name ?? slug, location: j.location?.name ?? null,
        remote: /remote/i.test(`${j.title ?? ""} ${j.location?.name ?? ""}`),
        employment_type: null, category: j.departments?.[0]?.name ?? null,
        salary_min: sal.min, salary_max: sal.max, salary_currency: "USD",
        url: j.absolute_url, description: cap(desc),
        tags: (j.departments ?? []).map((d: any) => d.name).filter(Boolean).slice(0, 4),
        posted_at: j.updated_at ?? null, is_active: true,
      };
      if (row.url && row.external_id && fitsCriteria(row.title) && meetsSalary(row) && isRecent(row.posted_at)) rows.push(row);
    }
    fetched += rows.length; upserted += await upsert(supabase, rows);
  });
  return { fetched, upserted };
}
// deno-lint-ignore no-explicit-any
async function fromLever(supabase: any, list: Src[]): Promise<Report> {
  let fetched = 0, upserted = 0;
  await runLimit(list, 4, async ({ slug, company_name }) => {
    const res = await fetch(`https://api.lever.co/v0/postings/${slug}?mode=json`);
    if (!res.ok) return;
    const arr = await res.json();
    const rows: JobRow[] = [];
    for (const j of (Array.isArray(arr) ? arr : [])) {
      const desc = j.descriptionPlain || htmlToText(j.description);
      const sal = extractSalary(desc);
      const loc = j.categories?.location ?? null;
      const row: JobRow = {
        source: "lever", external_id: `lever:${slug}:${j.id}`, title: j.text ?? "Untitled",
        company: company_name ?? slug, location: loc,
        remote: (j.workplaceType === "remote") || /remote/i.test(`${j.text ?? ""} ${loc ?? ""}`),
        employment_type: j.categories?.commitment ?? null, category: j.categories?.team ?? j.categories?.department ?? null,
        salary_min: sal.min, salary_max: sal.max, salary_currency: "USD",
        url: j.hostedUrl, description: cap(desc),
        tags: [j.categories?.department, j.categories?.team].filter(Boolean).slice(0, 4),
        posted_at: j.createdAt ? new Date(j.createdAt).toISOString() : null, is_active: true,
      };
      if (row.url && row.external_id && fitsCriteria(row.title) && meetsSalary(row) && isRecent(row.posted_at)) rows.push(row);
    }
    fetched += rows.length; upserted += await upsert(supabase, rows);
  });
  return { fetched, upserted };
}
// deno-lint-ignore no-explicit-any
async function fromAshby(supabase: any, list: Src[]): Promise<Report> {
  let fetched = 0, upserted = 0;
  await runLimit(list, 4, async ({ slug, company_name }) => {
    const res = await fetch(`https://api.ashbyhq.com/posting-api/job-board/${slug}?includeCompensation=true`);
    if (!res.ok) return;
    const json = await res.json();
    const rows: JobRow[] = [];
    for (const j of (json?.jobs ?? [])) {
      const desc = j.descriptionPlain || htmlToText(j.descriptionHtml);
      const sal = extractSalary(j.compensation?.compensationTierSummary || desc);
      const row: JobRow = {
        source: "ashby", external_id: `ashby:${slug}:${j.id}`, title: j.title ?? "Untitled",
        company: company_name ?? slug, location: j.location ?? null,
        remote: !!j.isRemote || /remote/i.test(j.location ?? ""),
        employment_type: j.employmentType ?? null, category: j.department ?? j.team ?? null,
        salary_min: sal.min, salary_max: sal.max, salary_currency: "USD",
        url: j.jobUrl || j.applyUrl, description: cap(desc),
        tags: [j.department, j.team].filter(Boolean).slice(0, 4),
        posted_at: j.publishedAt ?? null, is_active: true,
      };
      if (row.url && row.external_id && fitsCriteria(row.title) && meetsSalary(row) && isRecent(row.posted_at)) rows.push(row);
    }
    fetched += rows.length; upserted += await upsert(supabase, rows);
  });
  return { fetched, upserted };
}

// ---- Workday — enterprise boards. Each row carries tenant(slug)+datacenter+site.
// Listing is POST /wday/cxs/{tenant}/{site}/jobs (paginated); full description is a
// second GET on externalPath. Boards are huge, so we drive with searchText on the
// target titles (keeps each company to a few relevant pages) and only fetch detail
// for title-fitting, not-obviously-stale postings — bounding requests + memory.
const WD_SEARCH = ["product manager", "business analyst", "customer experience",
  "implementation consultant", "management consultant", "transformation", "analytics"];
const WD_HEADERS = { "content-type": "application/json", "accept": "application/json", "user-agent": "Mozilla/5.0 (gigcute)" };
function wdMaybeRecent(postedOn: string | null | undefined): boolean {
  // Listing gives relative text ("Posted Today", "Posted 30+ Days Ago"). Cheap
  // pre-filter to skip clearly-old postings before the detail call; startDate is
  // the real gate. Unknown formats pass through to the detail check.
  if (!postedOn) return true;
  const s = postedOn.toLowerCase();
  if (s.includes("today") || s.includes("yesterday")) return true;
  const m = s.match(/(\d+)\s*\+?\s*day/);
  return m ? parseInt(m[1], 10) <= MAX_AGE_DAYS : true;
}
// deno-lint-ignore no-explicit-any
async function fromWorkday(supabase: any, list: Src[]): Promise<Report> {
  let fetched = 0, upserted = 0;
  await runLimit(list, 2, async ({ slug: tenant, company_name, datacenter: dc, site }) => {
    if (!dc || !site) return;
    const base = `https://${tenant}.${dc}.myworkdayjobs.com/wday/cxs/${tenant}/${site}`;
    const seen = new Set<string>();
    let details = 0;                       // per-company detail-fetch cap (bounds cost)
    for (const term of WD_SEARCH) {
      for (let offset = 0; offset < 40; offset += 20) {   // up to 2 pages per term
        let res: Response;
        try { res = await fetch(`${base}/jobs`, { method: "POST", headers: WD_HEADERS, body: JSON.stringify({ appliedFacets: {}, limit: 20, offset, searchText: term }) }); }
        catch { break; }
        if (!res.ok) break;
        const j = await res.json();
        const posts = j?.jobPostings ?? [];
        if (!posts.length) break;
        const rows: JobRow[] = [];
        for (const p of posts) {
          if (details >= 40) break;
          if (!fitsCriteria(p.title) || !wdMaybeRecent(p.postedOn)) continue;
          if (!p.externalPath || seen.has(p.externalPath)) continue;
          seen.add(p.externalPath); details++;
          let info: any = {};
          try { const d = await fetch(`${base}${p.externalPath}`, { headers: WD_HEADERS }); if (!d.ok) continue; info = (await d.json())?.jobPostingInfo ?? {}; }
          catch { continue; }
          const desc = htmlToText(info.jobDescription);
          const sal = extractSalary(desc);
          const loc = info.location ?? p.locationsText ?? null;
          const row: JobRow = {
            source: "workday", external_id: `wd:${tenant}:${info.id ?? info.jobReqId ?? p.externalPath}`,
            title: info.title ?? p.title ?? "Untitled", company: company_name ?? tenant, location: loc,
            remote: /remote/i.test(`${info.remoteType ?? ""} ${p.remoteType ?? ""} ${loc ?? ""}`),
            employment_type: info.timeType ?? null, category: null,
            salary_min: sal.min, salary_max: sal.max, salary_currency: "USD",
            url: info.externalUrl || `https://${tenant}.${dc}.myworkdayjobs.com/${site}${p.externalPath}`,
            description: cap(desc), tags: [], posted_at: info.startDate ?? null, is_active: true,
          };
          if (row.url && meetsSalary(row) && isRecent(row.posted_at)) rows.push(row);
        }
        if (rows.length) { fetched += rows.length; upserted += await upsert(supabase, rows); }
        if (posts.length < 20 || details >= 40) break;
      }
    }
  });
  return { fetched, upserted };
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("CRON_SECRET");
  const given = req.headers.get("x-cron-secret") || new URL(req.url).searchParams.get("secret");
  if (!secret || given !== secret) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: { "content-type": "application/json" } });
  }
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  // Process only a BATCH of ATS companies per run (oldest-ingested first) so one
  // invocation stays under the worker limit; the hourly cron cycles through them
  // all. Scales to thousands of slugs. Tune with the ATS_BATCH secret.
  const BATCH = Math.max(1, parseInt(Deno.env.get("ATS_BATCH") || "20", 10));
  const slugsBy: Record<string, Src[]> = {};
  const batchIds: string[] = [];
  try {
    const { data } = await supabase.from("job_sources")
      .select("id, platform, slug, company_name, datacenter, site").eq("active", true)
      .order("last_ingested_at", { ascending: true, nullsFirst: true }).limit(BATCH);
    for (const r of (data ?? [])) { (slugsBy[r.platform] ??= []).push({ slug: r.slug, company_name: r.company_name, datacenter: r.datacenter, site: r.site }); batchIds.push(r.id); }
  } catch (_e) { /* table/column may not exist yet */ }

  const runners: [string, () => Promise<Report>][] = [
    ["greenhouse", () => fromGreenhouse(supabase, slugsBy.greenhouse ?? [])],
    ["lever", () => fromLever(supabase, slugsBy.lever ?? [])],
    ["ashby", () => fromAshby(supabase, slugsBy.ashby ?? [])],
    ["workday", () => fromWorkday(supabase, slugsBy.workday ?? [])],
  ];
  const report: Record<string, Report> = {};
  for (const [name, fn] of runners) {
    try { report[name] = await fn(); }
    catch (e) { report[name] = { fetched: 0, upserted: 0, error: String((e as Error)?.message ?? e) }; }
  }
  // Mark this batch as ingested so the next run rotates to the next companies.
  if (batchIds.length) {
    try { await supabase.from("job_sources").update({ last_ingested_at: new Date().toISOString() }).in("id", batchIds); } catch (_e) { /* ignore */ }
  }
  // Retention: drop jobs older than JOB_RETENTION_DAYS (default 30) so the board
  // stays current. (Intake caps at MAX_AGE_DAYS; this removes rows that have since aged.)
  let purged = 0;
  try {
    const cutoff = new Date(Date.now() - RETENTION_DAYS * 86400000).toISOString();
    const { data } = await supabase.from("jobs").delete().lt("posted_at", cutoff).select("id");
    purged = (data ?? []).length;
  } catch (_e) { /* ignore */ }
  return new Response(JSON.stringify({ ok: true, report, atsBatch: batchIds.length, purged }, null, 2), { headers: { "content-type": "application/json" } });
});
