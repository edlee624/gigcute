// ============================================================================
// GigCute — ingest-jobs Edge Function
// Pulls job listings from public job APIs, normalizes them, and upserts into
// public.jobs (deduped by source + external_id). Meant to be called on a
// schedule (Supabase Cron / pg_cron). Deploy with JWT verification OFF and
// protect it with the CRON_SECRET header instead.
//
// Env (Project Settings → Edge Functions → Secrets):
//   CRON_SECRET          required — shared secret; callers must send it
//   ADZUNA_APP_ID        optional — enables the Adzuna source (broad coverage)
//   ADZUNA_APP_KEY       optional — "
//   ADZUNA_COUNTRY       optional — 2-letter country (default "us")
//   ADZUNA_PAGES         optional — how many 50-result pages to pull (default 2)
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
  })).filter((r: JobRow) => r.url && r.external_id && r.remote); // US/Remote focus: keep remote roles only
}

// ---- Source: Adzuna (broad; needs a free app_id + app_key) ------------------
async function fromAdzuna(): Promise<JobRow[]> {
  const id = Deno.env.get("ADZUNA_APP_ID");
  const key = Deno.env.get("ADZUNA_APP_KEY");
  if (!id || !key) return []; // source disabled until keys are set
  const country = (Deno.env.get("ADZUNA_COUNTRY") || "us").toLowerCase();
  const pages = Math.max(1, Math.min(10, parseInt(Deno.env.get("ADZUNA_PAGES") || "2", 10)));
  const out: JobRow[] = [];
  for (let page = 1; page <= pages; page++) {
    const u = new URL(`https://api.adzuna.com/v1/api/jobs/${country}/search/${page}`);
    u.searchParams.set("app_id", id);
    u.searchParams.set("app_key", key);
    u.searchParams.set("results_per_page", "50");
    u.searchParams.set("max_days_old", "30");
    u.searchParams.set("content-type", "application/json");
    const res = await fetch(u.toString());
    if (!res.ok) throw new Error(`adzuna ${res.status} (page ${page})`);
    const json = await res.json();
    const items = Array.isArray(json?.results) ? json.results : [];
    for (const j of items) {
      const desc = stripHtml(j.description);
      out.push({
        source: "adzuna",
        external_id: String(j.id),
        title: j.title ?? "Untitled",
        company: j.company?.display_name ?? null,
        location: j.location?.display_name ?? null,
        remote: /remote/i.test(`${j.title ?? ""} ${j.location?.display_name ?? ""} ${desc ?? ""}`),
        employment_type: j.contract_time ?? j.contract_type ?? null,
        category: j.category?.label ?? null,
        salary_min: typeof j.salary_min === "number" ? j.salary_min : null,
        salary_max: typeof j.salary_max === "number" ? j.salary_max : null,
        salary_currency: country === "us" ? "USD" : null,
        url: j.redirect_url,
        description: desc,
        tags: j.category?.label ? [j.category.label] : [],
        posted_at: j.created ?? null,
        is_active: true,
      });
    }
    if (items.length < 50) break; // no more pages
  }
  return out.filter((r) => r.url && r.external_id);
}

const SOURCES: Record<string, () => Promise<JobRow[]>> = {
  arbeitnow: fromArbeitnow,
  adzuna: fromAdzuna,
};

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

  const report: Record<string, { fetched: number; upserted: number; error?: string }> = {};
  for (const [name, fn] of Object.entries(SOURCES)) {
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
