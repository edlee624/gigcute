// ============================================================================
// GigCute — ingest-jobs Edge Function
// Pulls job listings from public job APIs, normalizes them, and upserts into
// public.jobs (deduped by source + external_id). Meant to be called on a
// schedule (Supabase Cron / pg_cron). Deploy with JWT verification OFF and
// protect it with the CRON_SECRET header instead.
//
// Env (Project Settings → Edge Functions → Secrets):
//   CRON_SECRET          required — shared secret; callers must send it
//   ADZUNA_APP_ID        optional — enables the Adzuna source
//   ADZUNA_APP_KEY       optional — "
//   ADZUNA_COUNTRY       optional — 2-letter country (default "us")
//   ADZUNA_PAGES         optional — how many 50-result pages per query (default 3)
//   ADZUNA_WHAT_OR       optional — broad OR keywords to bias Adzuna's domain
//   ADZUNA_WHERE         optional — CSV location anchors (default "New York")
//   ADZUNA_DISTANCE_KM   optional — radius per anchor (default 120)
//   JOB_TITLE_ANY        optional — CSV role phrases; title must contain one
//   JOB_SENIORITY_ANY    optional — CSV seniority levels; title must contain one
//   JOB_MIN_SALARY       optional — minimum pay floor (default 100000; 0 = off)
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type JobRow = {
  source: string;
  external_id: string;
  title: string;
  company: string | null;
  location: string | null;
  remote: boolean;
  employment_type: string | null;
  category: string | null;
  salary_min: number | null;
  salary_max: number | null;
  salary_currency: string | null;
  url: string;
  description: string | null;
  tags: string[];
  posted_at: string | null;
  is_active: boolean;
};

const stripHtml = (s: string | null | undefined): string | null =>
  s ? s.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim() : null;

// ---- Fit filter (shared by all sources) ------------------------------------
// A job is kept only if its TITLE contains one of the target role phrases AND
// one of the target seniority levels. Both lists are env-configurable (CSV).
function csvEnv(name: string, def: string): string[] {
  return (Deno.env.get(name) || def).split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
}
const TITLE_ANY = csvEnv(
  "JOB_TITLE_ANY",
  "cx,analyt,product manager,implementation consultant,transformation,management consultant,ai consultant,business analyst,customer experience",
);
const SENIORITY_ANY = csvEnv(
  "JOB_SENIORITY_ANY",
  "senior manager,manager,director,avp,vp,svp,vice president,head of",
);
const SENIORITY_RE = SENIORITY_ANY.map(
  (s) => new RegExp(`\\b${s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`, "i"),
);
function fitsCriteria(title: string | null | undefined): boolean {
  const t = (title || "").toLowerCase();
  if (!t) return false;
  const roleOk = TITLE_ANY.some((k) => t.includes(k));
  const senOk = SENIORITY_RE.some((re) => re.test(t));
  return roleOk && senOk;
}
// Minimum salary gate. A job passes if either salary bound reaches the floor.
// Jobs with NO salary data are dropped when a floor is set (can't confirm pay).
const JOB_MIN_SALARY = Math.max(0, parseInt(Deno.env.get("JOB_MIN_SALARY") || "100000", 10) || 0);
function meetsSalary(r: { salary_min: number | null; salary_max: number | null }): boolean {
  if (JOB_MIN_SALARY <= 0) return true;
  return (r.salary_max != null && r.salary_max >= JOB_MIN_SALARY) ||
         (r.salary_min != null && r.salary_min >= JOB_MIN_SALARY);
}

// Decode common HTML entities + strip tags to readable plain text (for ATS feeds
// that return full HTML descriptions).
function htmlToText(s: string | null | undefined): string | null {
  if (!s) return null;
  return s
    .replace(/<\/(p|div|li|br|h[1-6]|ul|ol|tr)>/gi, "\n")
    .replace(/<li[^>]*>/gi, "• ")
    .replace(/<[^>]*>/g, " ")
    .replace(/&nbsp;/gi, " ").replace(/&amp;/gi, "&").replace(/&lt;/gi, "<").replace(/&gt;/gi, ">")
    .replace(/&#39;|&rsquo;|&apos;/gi, "'").replace(/&quot;|&ldquo;|&rdquo;/gi, '"')
    .replace(/&mdash;/gi, "—").replace(/&ndash;/gi, "–").replace(/&hellip;/gi, "…")
    .replace(/&#(\d+);/g, (_m, n) => String.fromCharCode(+n))
    .replace(/[ \t]+/g, " ").replace(/\n{3,}/g, "\n\n").trim();
}
// Best-effort salary extraction from free text ($120,000 / $120k / $120K ranges).
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
  if (!nums.length) return { min: null, max: null };
  return { min: Math.min(...nums), max: Math.max(...nums) };
}
type Src = { slug: string; company_name?: string | null };

// ---- Source: Arbeitnow (free, no key) --------------------------------------
async function fromArbeitnow(): Promise<JobRow[]> {
  const res = await fetch("https://www.arbeitnow.com/api/job-board-api");
  if (!res.ok) throw new Error(`arbeitnow ${res.status}`);
  const json = await res.json();
  const items = Array.isArray(json?.data) ? json.data : [];
  return items.map((j: any): JobRow => ({
    source: "arbeitnow",
    external_id: String(j.slug ?? j.url),
    title: j.title ?? "Untitled",
    company: j.company_name ?? null,
    location: j.location ?? null,
    remote: !!j.remote,
    employment_type: Array.isArray(j.job_types) ? (j.job_types[0] ?? null) : null,
    category: null,
    salary_min: null,
    salary_max: null,
    salary_currency: null,
    url: j.url,
    description: stripHtml(j.description),
    tags: Array.isArray(j.tags) ? j.tags.slice(0, 12).map(String) : [],
    posted_at: j.created_at ? new Date(j.created_at * 1000).toISOString() : null,
    is_active: true,
  })).filter((r: JobRow) => r.url && r.external_id && r.remote && fitsCriteria(r.title) && meetsSalary(r)); // remote + fit + pay
}

// ---- Source: Adzuna (targeted; needs a free app_id + app_key) ---------------
// Tuned to a person's fit + geography via env secrets:
//   ADZUNA_WHAT_OR       broad OR keywords to bias the domain (local title filter narrows)
//   ADZUNA_WHERE         comma-separated location anchors, e.g. "New York,Hartford"
//   ADZUNA_DISTANCE_KM   radius around each anchor (default 120 — covers the NY/NJ/CT metro)
//   ADZUNA_PAGES         pages (×50) per query (default 3)
//   ADZUNA_COUNTRY       2-letter country (default "us")
// Also honors the shared JOB_TITLE_ANY / JOB_SENIORITY_ANY / JOB_MIN_SALARY gates.
// Sorted by date (newest). One pass per location anchor + a US-wide remote pass.
async function fromAdzuna(): Promise<JobRow[]> {
  const id = Deno.env.get("ADZUNA_APP_ID");
  const key = Deno.env.get("ADZUNA_APP_KEY");
  if (!id || !key) return []; // source disabled until keys are set
  const country = (Deno.env.get("ADZUNA_COUNTRY") || "us").toLowerCase();
  const pages = Math.max(1, Math.min(10, parseInt(Deno.env.get("ADZUNA_PAGES") || "3", 10)));
  // Broad OR keywords bias Adzuna toward the domain; the local fitsCriteria()
  // title filter (role + seniority) does the precise narrowing.
  const whatOr = (Deno.env.get("ADZUNA_WHAT_OR") ||
    "analytics product consultant transformation strategy customer experience implementation").trim();
  const where = (Deno.env.get("ADZUNA_WHERE") || "New York").split(",").map((s) => s.trim()).filter(Boolean);
  const distance = (Deno.env.get("ADZUNA_DISTANCE_KM") || "120").trim();

  // One pass per location anchor (kept regardless of remote flag) + one remote pass
  // (US-wide, remote roles only). keepRemoteOnly drops on-site jobs from that pass.
  type Pass = { label: string; where?: string; remoteOnly?: boolean };
  const passes: Pass[] = where.map((w) => ({ label: `loc:${w}`, where: w }));
  passes.push({ label: "remote", remoteOnly: true });

  const out: JobRow[] = [];
  for (const pass of passes) {
    for (let page = 1; page <= pages; page++) {
      const u = new URL(`https://api.adzuna.com/v1/api/jobs/${country}/search/${page}`);
      u.searchParams.set("app_id", id);
      u.searchParams.set("app_key", key);
      u.searchParams.set("results_per_page", "50");
      u.searchParams.set("max_days_old", "30");
      u.searchParams.set("sort_by", "date"); // newest postings first
      u.searchParams.set("content-type", "application/json");
      if (JOB_MIN_SALARY > 0) u.searchParams.set("salary_min", String(JOB_MIN_SALARY));
      if (whatOr) u.searchParams.set("what_or", whatOr);
      if (pass.where) { u.searchParams.set("where", pass.where); if (distance) u.searchParams.set("distance", distance); }
      const res = await fetch(u.toString());
      if (!res.ok) throw new Error(`adzuna ${res.status} (${pass.label} p${page})`);
      const json = await res.json();
      const items = Array.isArray(json?.results) ? json.results : [];
      for (const j of items) {
        const desc = stripHtml(j.description);
        const remote = /remote/i.test(`${j.title ?? ""} ${j.location?.display_name ?? ""} ${desc ?? ""}`);
        if (pass.remoteOnly && !remote) continue;
        if (!fitsCriteria(j.title)) continue; // role + seniority fit
        const salMin = typeof j.salary_min === "number" ? j.salary_min : null;
        const salMax = typeof j.salary_max === "number" ? j.salary_max : null;
        if (!meetsSalary({ salary_min: salMin, salary_max: salMax })) continue; // pay floor
        out.push({
          source: "adzuna",
          external_id: String(j.id),
          title: j.title ?? "Untitled",
          company: j.company?.display_name ?? null,
          location: j.location?.display_name ?? null,
          remote,
          employment_type: j.contract_time ?? j.contract_type ?? null,
          category: j.category?.label ?? null,
          salary_min: salMin,
          salary_max: salMax,
          salary_currency: country === "us" ? "USD" : null,
          url: j.redirect_url,
          description: desc,
          tags: j.category?.label ? [j.category.label] : [],
          posted_at: j.created ?? null,
          is_active: true,
        });
      }
      if (items.length < 50) break; // no more pages for this pass
    }
  }
  return out.filter((r) => r.url && r.external_id);
}

// ---- ATS sources (full descriptions; per-company slugs from job_sources) -----
// Broad: all roles, but only kept when a detected salary meets JOB_MIN_SALARY.
async function fromGreenhouse(list: Src[]): Promise<JobRow[]> {
  const out: JobRow[] = [];
  for (const { slug, company_name } of list) {
    try {
      const res = await fetch(`https://boards-api.greenhouse.io/v1/boards/${slug}/jobs?content=true`);
      if (!res.ok) continue;
      const json = await res.json();
      for (const j of (json?.jobs ?? [])) {
        const desc = htmlToText(j.content);
        const sal = extractSalary(desc);
        const row: JobRow = {
          source: "greenhouse", external_id: `gh:${slug}:${j.id}`,
          title: j.title ?? "Untitled", company: company_name ?? slug,
          location: j.location?.name ?? null,
          remote: /remote/i.test(`${j.title ?? ""} ${j.location?.name ?? ""}`),
          employment_type: null, category: j.departments?.[0]?.name ?? null,
          salary_min: sal.min, salary_max: sal.max, salary_currency: "USD",
          url: j.absolute_url, description: desc,
          tags: (j.departments ?? []).map((d: any) => d.name).filter(Boolean).slice(0, 4),
          posted_at: j.updated_at ?? null, is_active: true,
        };
        if (row.url && row.external_id && meetsSalary(row)) out.push(row);
      }
    } catch (_e) { /* skip bad/embed-only slug */ }
  }
  return out;
}
async function fromLever(list: Src[]): Promise<JobRow[]> {
  const out: JobRow[] = [];
  for (const { slug, company_name } of list) {
    try {
      const res = await fetch(`https://api.lever.co/v0/postings/${slug}?mode=json`);
      if (!res.ok) continue;
      const arr = await res.json();
      for (const j of (Array.isArray(arr) ? arr : [])) {
        const desc = j.descriptionPlain || htmlToText(j.description);
        const sal = extractSalary(desc);
        const loc = j.categories?.location ?? null;
        const row: JobRow = {
          source: "lever", external_id: `lever:${slug}:${j.id}`,
          title: j.text ?? "Untitled", company: company_name ?? slug, location: loc,
          remote: (j.workplaceType === "remote") || /remote/i.test(`${j.text ?? ""} ${loc ?? ""}`),
          employment_type: j.categories?.commitment ?? null,
          category: j.categories?.team ?? j.categories?.department ?? null,
          salary_min: sal.min, salary_max: sal.max, salary_currency: "USD",
          url: j.hostedUrl, description: desc,
          tags: [j.categories?.department, j.categories?.team].filter(Boolean).slice(0, 4),
          posted_at: j.createdAt ? new Date(j.createdAt).toISOString() : null, is_active: true,
        };
        if (row.url && row.external_id && meetsSalary(row)) out.push(row);
      }
    } catch (_e) { /* skip */ }
  }
  return out;
}
async function fromAshby(list: Src[]): Promise<JobRow[]> {
  const out: JobRow[] = [];
  for (const { slug, company_name } of list) {
    try {
      const res = await fetch(`https://api.ashbyhq.com/posting-api/job-board/${slug}?includeCompensation=true`);
      if (!res.ok) continue;
      const json = await res.json();
      for (const j of (json?.jobs ?? [])) {
        const desc = j.descriptionPlain || htmlToText(j.descriptionHtml);
        const sal = extractSalary(j.compensation?.compensationTierSummary || desc);
        const row: JobRow = {
          source: "ashby", external_id: `ashby:${slug}:${j.id}`,
          title: j.title ?? "Untitled", company: company_name ?? slug,
          location: j.location ?? null, remote: !!j.isRemote || /remote/i.test(j.location ?? ""),
          employment_type: j.employmentType ?? null, category: j.department ?? j.team ?? null,
          salary_min: sal.min, salary_max: sal.max, salary_currency: "USD",
          url: j.jobUrl || j.applyUrl, description: desc,
          tags: [j.department, j.team].filter(Boolean).slice(0, 4),
          posted_at: j.publishedAt ?? null, is_active: true,
        };
        if (row.url && row.external_id && meetsSalary(row)) out.push(row);
      }
    } catch (_e) { /* skip */ }
  }
  return out;
}

Deno.serve(async (req) => {
  // Auth: shared-secret header (function is deployed with verify_jwt = false).
  const secret = Deno.env.get("CRON_SECRET");
  const given = req.headers.get("x-cron-secret") || new URL(req.url).searchParams.get("secret");
  if (!secret || given !== secret) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: { "content-type": "application/json" } });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  // ATS company slugs to pull full-description jobs from (job_sources table).
  const slugsBy: Record<string, Src[]> = {};
  try {
    const { data } = await supabase.from("job_sources").select("platform, slug, company_name").eq("active", true);
    for (const r of (data ?? [])) { (slugsBy[r.platform] ??= []).push({ slug: r.slug, company_name: r.company_name }); }
  } catch (_e) { /* table may not exist yet */ }

  const runners: [string, () => Promise<JobRow[]>][] = [
    ["arbeitnow", fromArbeitnow],
    ["adzuna", fromAdzuna],
    ["greenhouse", () => fromGreenhouse(slugsBy.greenhouse ?? [])],
    ["lever", () => fromLever(slugsBy.lever ?? [])],
    ["ashby", () => fromAshby(slugsBy.ashby ?? [])],
  ];

  const report: Record<string, { fetched: number; upserted: number; error?: string }> = {};
  for (const [name, fn] of runners) {
    try {
      const rows = await fn();
      let upserted = 0;
      // upsert in chunks, deduped on (source, external_id)
      for (let i = 0; i < rows.length; i += 200) {
        const chunk = rows.slice(i, i + 200);
        const { error } = await supabase.from("jobs").upsert(chunk, { onConflict: "source,external_id" });
        if (error) throw error;
        upserted += chunk.length;
      }
      report[name] = { fetched: rows.length, upserted };
    } catch (e) {
      report[name] = { fetched: 0, upserted: 0, error: String((e as Error)?.message ?? e) };
    }
  }

  return new Response(JSON.stringify({ ok: true, report }, null, 2), {
    headers: { "content-type": "application/json" },
  });
});
