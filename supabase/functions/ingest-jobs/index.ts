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
  tags: string[]; posted_at: string | null; is_active: boolean; last_seen_at?: string;
};
type Src = { id?: string; slug: string; company_name?: string | null; datacenter?: string | null; site?: string | null };
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
const MAX_AGE_DAYS = Math.max(1, parseInt(Deno.env.get("JOB_MAX_AGE_DAYS") || "14", 10) || 14);
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
  const seen = new Date().toISOString();
  // Dedupe by external_id — a single upsert payload can't carry the same conflict
  // key twice (Postgres 21000), and some boards list a posting twice / reuse an id.
  if (rows.length > 1) {
    const byId = new Map<string, JobRow>();
    for (const r of rows) byId.set(r.external_id, r);
    rows = [...byId.values()];
  }
  for (let i = 0; i < rows.length; i += 200) {
    const chunk = rows.slice(i, i + 200).map((r) => ({ ...r, last_seen_at: seen }));
    const { error } = await supabase.from("jobs").upsert(chunk, { onConflict: "source,external_id" });
    if (error) throw error;
    n += chunk.length;
  }
  return n;
}
// Reconcile one company's board: refresh last_seen_at on every job still listed
// (allIds = the FULL board, before recency filters) and deactivate ours that
// dropped off (closed at the source). Only for sources where we fetch the whole
// board (greenhouse/lever/ashby) — Workday is a partial fetch, never reconciled.
// deno-lint-ignore no-explicit-any
async function reconcile(supabase: any, source: string, prefix: string, allIds: string[]): Promise<void> {
  try { await supabase.rpc("touch_and_reconcile", { p_source: source, p_prefix: prefix, p_seen: allIds }); }
  catch (_e) { /* reconciliation is best-effort */ }
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
    const allIds: string[] = (json?.jobs ?? []).map((j: any) => `gh:${slug}:${j.id}`);
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
      if (row.url && row.external_id && isRecent(row.posted_at)) rows.push(row);
    }
    fetched += rows.length; upserted += await upsert(supabase, rows);
    await reconcile(supabase, "greenhouse", `gh:${slug}:%`, allIds);
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
    const allIds: string[] = (Array.isArray(arr) ? arr : []).map((j: any) => `lever:${slug}:${j.id}`);
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
      if (row.url && row.external_id && isRecent(row.posted_at)) rows.push(row);
    }
    fetched += rows.length; upserted += await upsert(supabase, rows);
    await reconcile(supabase, "lever", `lever:${slug}:%`, allIds);
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
    const allIds: string[] = (json?.jobs ?? []).map((j: any) => `ashby:${slug}:${j.id}`);
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
      if (row.url && row.external_id && isRecent(row.posted_at)) rows.push(row);
    }
    fetched += rows.length; upserted += await upsert(supabase, rows);
    await reconcile(supabase, "ashby", `ashby:${slug}:%`, allIds);
  });
  return { fetched, upserted };
}

// ---- Workday — enterprise boards. Each row carries tenant(slug)+datacenter+site.
// Listing is POST /wday/cxs/{tenant}/{site}/jobs (paginated); full description is a
// second GET on externalPath. Boards are huge and each job needs a detail call, so
// we cap detail fetches per company (below). Broad mode: empty searchText = the
// general listing (all roles). Add title terms here to bias/expand coverage.
const WD_SEARCH = [""];
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
          if (!wdMaybeRecent(p.postedOn)) continue;
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
          if (row.url && isRecent(row.posted_at)) rows.push(row);
        }
        if (rows.length) { fetched += rows.length; upserted += await upsert(supabase, rows); }
        if (posts.length < 20 || details >= 40) break;
      }
    }
  });
  return { fetched, upserted };
}

// ---- Clean-JSON ATS tier (Workable / Recruitee / SmartRecruiters / BambooHR) --
// Same public-JSON pattern as above. Workable + Recruitee are 1-hop (description
// in the list, reconcilable). SmartRecruiters + BambooHR are 2-hop (a detail call
// per posting): SR pre-filters by releasedDate before the detail call; BambooHR's
// list has no date, so it detail-fetches up to a cap (like Workday) — never reconciled.
const UA_H = { "user-agent": "Mozilla/5.0 (gigcute)" };
function locStr(d: any): string | null {
  if (!d) return null;
  if (typeof d === "string") return d;
  for (const k of ["fullLocation", "name", "label"]) if (d[k]) return d[k];
  const parts = [d.city, d.region ?? d.state, d.country ?? d.countryCode].filter(Boolean);
  return parts.length ? parts.join(", ") : null;
}
// deno-lint-ignore no-explicit-any
async function fromWorkable(supabase: any, list: Src[]): Promise<Report> {
  let fetched = 0, upserted = 0;
  await runLimit(list, 4, async ({ slug, company_name }) => {
    const res = await fetch(`https://apply.workable.com/api/v1/widget/accounts/${slug}?details=true`, { headers: UA_H });
    if (!res.ok) return;
    const acct = await res.json();
    const cname = acct?.name ?? company_name ?? slug;
    const jobs = acct?.jobs ?? [];
    const rows: JobRow[] = [];
    const allIds: string[] = jobs.map((j: any) => `workable:${slug}:${j.shortcode ?? j.id}`);
    for (const j of jobs) {
      const desc = htmlToText(j.description);
      const sal = extractSalary(desc);
      const code = j.shortcode ?? j.id;
      const loc = locStr({ city: j.city, state: j.state, country: j.country }) ?? (j.locations?.[0]?.city ?? null);
      const dep = j.department ?? j.function ?? null;
      const row: JobRow = {
        source: "workable", external_id: `workable:${slug}:${code}`, title: j.title ?? "Untitled",
        company: cname, location: loc, remote: !!(j.telecommuting || j.remote),
        employment_type: j.employment_type ?? null, category: dep,
        salary_min: sal.min, salary_max: sal.max, salary_currency: "USD",
        url: j.url || j.application_url || (code ? `https://apply.workable.com/${slug}/j/${code}/` : ""),
        description: cap(desc), tags: [dep, j.industry].filter(Boolean).slice(0, 4),
        posted_at: j.published_on ?? j.created_at ?? null, is_active: true,
      };
      if (row.url && isRecent(row.posted_at)) rows.push(row);
    }
    fetched += rows.length; upserted += await upsert(supabase, rows);
    await reconcile(supabase, "workable", `workable:${slug}:%`, allIds);
  });
  return { fetched, upserted };
}
// deno-lint-ignore no-explicit-any
async function fromRecruitee(supabase: any, list: Src[]): Promise<Report> {
  let fetched = 0, upserted = 0;
  await runLimit(list, 4, async ({ slug, company_name }) => {
    const res = await fetch(`https://${slug}.recruitee.com/api/offers/`, { headers: UA_H });
    if (!res.ok) return;
    const offers = (await res.json())?.offers ?? [];
    const rows: JobRow[] = [];
    const allIds: string[] = offers.map((j: any) => `recruitee:${slug}:${j.id}`);
    for (const j of offers) {
      const desc = (htmlToText(j.description) ?? "") + (j.requirements ? "\n\n" + (htmlToText(j.requirements) ?? "") : "");
      const sal = extractSalary(desc);
      const loc = locStr({ city: j.city, state: j.state_name ?? j.state_code, country: j.country ?? j.country_code }) ?? j.location ?? null;
      const row: JobRow = {
        source: "recruitee", external_id: `recruitee:${slug}:${j.id}`, title: j.title ?? "Untitled",
        company: company_name ?? slug, location: loc,
        remote: !!j.remote || String(j.employment_type_code ?? "").toLowerCase() === "remote",
        employment_type: j.employment_type_code ?? null, category: j.department ?? null,
        salary_min: sal.min, salary_max: sal.max, salary_currency: "USD",
        url: j.careers_url || j.careers_apply_url || "", description: cap(desc.trim()),
        tags: [j.department].filter(Boolean).slice(0, 4),
        posted_at: j.published_at ?? j.created_at ?? null, is_active: true,
      };
      if (row.url && isRecent(row.posted_at)) rows.push(row);
    }
    fetched += rows.length; upserted += await upsert(supabase, rows);
    await reconcile(supabase, "recruitee", `recruitee:${slug}:%`, allIds);
  });
  return { fetched, upserted };
}
// deno-lint-ignore no-explicit-any
async function fromSmartRecruiters(supabase: any, list: Src[]): Promise<Report> {
  let fetched = 0, upserted = 0;
  await runLimit(list, 3, async ({ slug, company_name }) => {
    let details = 0;                        // per-company detail-fetch cap (bounds cost)
    for (let offset = 0; offset < 300; offset += 100) {
      let res: Response;
      try { res = await fetch(`https://api.smartrecruiters.com/v1/companies/${slug}/postings?limit=100&offset=${offset}`, { headers: UA_H }); }
      catch { break; }
      if (!res.ok) break;
      const content = (await res.json())?.content ?? [];
      if (!content.length) break;
      const rows: JobRow[] = [];
      for (const p of content) {
        if (details >= 40) break;
        if (!isRecent(p.releasedDate ?? null)) continue;   // list has the date — pre-filter
        details++;
        let dj: any = {};
        try { const d = await fetch(`https://api.smartrecruiters.com/v1/companies/${slug}/postings/${p.id}`, { headers: UA_H }); if (!d.ok) continue; dj = await d.json(); }
        catch { continue; }
        const secs = dj?.jobAd?.sections ?? {};
        const desc = htmlToText(["jobDescription", "qualifications", "additionalInformation"]
          .map((k) => secs[k]?.text ?? "").join("\n\n"));
        const sal = extractSalary(desc);
        const loc = p.location ?? {};
        const dep = p.department?.label ?? null;
        const row: JobRow = {
          source: "smartrecruiters", external_id: `sr:${slug}:${p.id}`, title: p.name ?? "Untitled",
          company: p.company?.name ?? company_name ?? slug, location: locStr(loc),
          remote: !!loc.remote, employment_type: p.typeOfEmployment?.label ?? null, category: dep,
          salary_min: sal.min, salary_max: sal.max, salary_currency: "USD",
          url: dj.applyUrl || dj.postingUrl || p.postingUrl || `https://jobs.smartrecruiters.com/${slug}/${p.id}`,
          description: cap(desc), tags: [dep, p.function?.label].filter(Boolean).slice(0, 4),
          posted_at: p.releasedDate ?? null, is_active: true,
        };
        if (row.url) rows.push(row);
      }
      if (rows.length) { fetched += rows.length; upserted += await upsert(supabase, rows); }
      if (content.length < 100 || details >= 40) break;
    }
  });
  return { fetched, upserted };
}
// deno-lint-ignore no-explicit-any
async function fromBambooHR(supabase: any, list: Src[]): Promise<Report> {
  let fetched = 0, upserted = 0;
  await runLimit(list, 3, async ({ slug, company_name }) => {
    let res: Response;
    try { res = await fetch(`https://${slug}.bamboohr.com/careers/list`, { headers: UA_H }); }
    catch { return; }
    if (!res.ok) return;
    const result = (await res.json())?.result ?? [];
    let details = 0;
    const rows: JobRow[] = [];
    for (const j of result) {
      if (details >= 40) break;
      if (!j.id) continue;
      details++;
      let dj: any = {};
      try { const d = await fetch(`https://${slug}.bamboohr.com/careers/${j.id}/detail`, { headers: UA_H }); if (!d.ok) continue; dj = await d.json(); }
      catch { continue; }
      const jo = dj?.result?.jobOpening ?? {};
      if (!isRecent(jo.datePosted ?? null)) continue;
      const desc = htmlToText(jo.description);
      const sal = extractSalary(desc);
      const dep = j.departmentLabel ?? jo.departmentLabel ?? null;
      const row: JobRow = {
        source: "bamboohr", external_id: `bamboo:${slug}:${j.id}`,
        title: jo.jobOpeningName ?? j.jobOpeningName ?? "Untitled", company: company_name ?? slug,
        location: (typeof j.atsLocation === "string" ? j.atsLocation : null) ?? locStr(jo.location ?? j.location),
        remote: !!(j.isRemote) || String(j.locationType ?? "").toLowerCase() === "remote",
        employment_type: j.employmentStatusLabel ?? null, category: dep,
        salary_min: sal.min, salary_max: sal.max, salary_currency: "USD",
        url: jo.jobOpeningShareUrl || `https://${slug}.bamboohr.com/careers/${j.id}`,
        description: cap(desc), tags: [dep].filter(Boolean).slice(0, 4),
        posted_at: jo.datePosted ?? null, is_active: true,
      };
      if (row.url) rows.push(row);
    }
    if (rows.length) { fetched += rows.length; upserted += await upsert(supabase, rows); }
  });
  return { fetched, upserted };
}

Deno.serve(async (req) => {
  // Header only — query strings end up in proxy/edge logs (the cron sends the header).
  const secret = Deno.env.get("CRON_SECRET");
  const given = req.headers.get("x-cron-secret");
  if (!secret || given !== secret) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: { "content-type": "application/json" } });
  }
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  // Process only a BATCH of ATS companies per run (oldest-ingested first) so one
  // invocation stays under the worker limit; the hourly cron cycles through them
  // all. Scales to thousands of slugs. Tune with the ATS_BATCH secret.
  const BATCH = Math.max(1, parseInt(Deno.env.get("ATS_BATCH") || "40", 10));
  const HEAVY_PER_RUN = Math.max(1, parseInt(Deno.env.get("WORKDAY_PER_RUN") || "6", 10));
  // "Heavy" = one detail HTTP call per posting (Workday, SmartRecruiters, BambooHR).
  // They're numerous, so in a shared oldest-first rotation they'd bury the light
  // platforms (or an unlucky batch of 40 would blow the worker memory/time limit).
  // Give each a small per-run quota, then fill the rest from the light rotation.
  const HEAVY = ["workday", "smartrecruiters", "bamboohr"];
  const SEL = "id, platform, slug, company_name, datacenter, site";
  const slugsBy: Record<string, Src[]> = {};
  let batchIds: string[] = [];
  try {
    let picked: any[] = [];
    for (const plat of HEAVY) {
      const rows = (await supabase.from("job_sources").select(SEL).eq("active", true).eq("platform", plat)
        .order("last_ingested_at", { ascending: true, nullsFirst: true }).limit(HEAVY_PER_RUN)).data ?? [];
      picked = picked.concat(rows);
    }
    const restN = Math.max(0, BATCH - picked.length);
    const heavyList = `(${HEAVY.join(",")})`;
    const rest = restN > 0 ? ((await supabase.from("job_sources").select(SEL).eq("active", true).not("platform", "in", heavyList)
      .order("last_ingested_at", { ascending: true, nullsFirst: true }).limit(restN)).data ?? []) : [];
    picked = picked.concat(rest);
    for (const r of picked) { (slugsBy[r.platform] ??= []).push({ id: r.id, slug: r.slug, company_name: r.company_name, datacenter: r.datacenter, site: r.site }); }
    // Only mark the companies we actually process this run as ingested.
    batchIds = picked.map((r: { id: string }) => r.id).filter((x): x is string => !!x);
  } catch (_e) { /* table/column may not exist yet */ }

  const runners: [string, () => Promise<Report>][] = [
    ["greenhouse", () => fromGreenhouse(supabase, slugsBy.greenhouse ?? [])],
    ["lever", () => fromLever(supabase, slugsBy.lever ?? [])],
    ["ashby", () => fromAshby(supabase, slugsBy.ashby ?? [])],
    ["workday", () => fromWorkday(supabase, slugsBy.workday ?? [])],
    ["workable", () => fromWorkable(supabase, slugsBy.workable ?? [])],
    ["recruitee", () => fromRecruitee(supabase, slugsBy.recruitee ?? [])],
    ["smartrecruiters", () => fromSmartRecruiters(supabase, slugsBy.smartrecruiters ?? [])],
    ["bamboohr", () => fromBambooHR(supabase, slugsBy.bamboohr ?? [])],
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
