-- ============================================================================
-- GigCute — job_sources (ATS boards to ingest full-description jobs from)
-- Greenhouse / Lever / Ashby each expose a public JSON board API per company
-- ("slug"). The ingest-jobs Edge Function reads the active rows and pulls each
-- company's postings WITH full descriptions. Add companies here (no redeploy).
-- ============================================================================
create table if not exists public.job_sources (
  id           uuid primary key default gen_random_uuid(),
  platform     text not null check (platform in ('greenhouse','lever','ashby','workable')),
  slug         text not null,
  company_name text,
  active       boolean not null default true,
  last_ingested_at timestamptz,   -- rotation cursor: oldest gets ingested next
  created_at   timestamptz not null default now(),
  unique (platform, slug)
);
alter table public.job_sources add column if not exists last_ingested_at timestamptz;
alter table public.job_sources enable row level security;
drop policy if exists "job_sources: read" on public.job_sources;
create policy "job_sources: read" on public.job_sources for select using (true);
grant select on public.job_sources to anon, authenticated;

-- Seed a starter set of confirmed slugs (from the ATS research). The function
-- skips any that error, so dead/embed-only slugs are harmless.
insert into public.job_sources (platform, slug, company_name) values
  ('greenhouse','asana','Asana'),
  ('greenhouse','block','Block'),
  ('greenhouse','coupang','Coupang'),
  ('greenhouse','mongodb','MongoDB'),
  ('greenhouse','spacex','SpaceX'),
  ('greenhouse','andurilindustries','Anduril Industries'),
  ('greenhouse','dropbox','Dropbox'),
  ('greenhouse','fivetran','Fivetran'),
  ('greenhouse','moloco','Moloco'),
  ('greenhouse','appsflyer','AppsFlyer'),
  ('greenhouse','wizinc','Wiz'),
  ('greenhouse','formlabs','Formlabs'),
  ('greenhouse','upstart','Upstart'),
  ('greenhouse','classpass','ClassPass'),
  ('greenhouse','trustpilot','Trustpilot'),
  ('greenhouse','m1finance','M1 Finance'),
  ('greenhouse','mejuri','Mejuri'),
  ('greenhouse','nubank','Nubank'),
  ('greenhouse','ridgeline','Ridgeline'),
  ('greenhouse','gradle','Gradle'),
  ('greenhouse','elevatebio','ElevateBio'),
  ('greenhouse','wayfair','Wayfair'),
  ('greenhouse','carecom','Care.com'),
  ('greenhouse','traderepublic','Trade Republic'),
  ('greenhouse','stripe','Stripe'),
  ('greenhouse','databricks','Databricks'),
  ('greenhouse','anthropic','Anthropic'),
  ('greenhouse','figma','Figma'),
  ('lever','tala','Tala'),
  ('lever','peoplegrove','PeopleGrove'),
  ('lever','zoox','Zoox'),
  ('lever','includedhealth','Included Health'),
  ('lever','tonkean','Tonkean'),
  ('lever','voltus','Voltus'),
  ('lever','paytm','Paytm'),
  ('lever','azul','Azul'),
  ('lever','genefab','GeneFab'),
  ('ashby','higharc','Higharc'),
  ('ashby','legora','Legora'),
  ('ashby','riveron','Riveron'),
  ('ashby','upside','Upside'),
  ('ashby','deel','Deel'),
  ('ashby','notion','Notion'),
  ('ashby','ramp','Ramp')
on conflict (platform, slug) do nothing;
