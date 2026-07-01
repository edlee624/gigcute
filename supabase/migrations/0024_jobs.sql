-- ============================================================================
-- GigCute — jobs table (recruitment side)
-- Stores job listings ingested from public job APIs / ATS feeds by the
-- `ingest-jobs` Edge Function. Public read (active jobs only); writes happen via
-- the service role (Edge Function), which bypasses RLS.
-- ============================================================================
create table if not exists public.jobs (
  id              uuid primary key default gen_random_uuid(),
  source          text not null,               -- e.g. 'adzuna', 'arbeitnow'
  external_id     text not null,               -- the source's own unique id
  title           text not null,
  company         text,
  location        text,
  remote          boolean not null default false,
  employment_type text,                        -- full_time, contract, etc. (best effort)
  category        text,                         -- source-provided category/industry
  salary_min      numeric,
  salary_max      numeric,
  salary_currency text,
  url             text not null,               -- apply / detail link on the source
  description     text,
  tags            text[] not null default '{}',
  posted_at       timestamptz,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (source, external_id)
);

create index if not exists jobs_posted_idx  on public.jobs (posted_at desc nulls last);
create index if not exists jobs_active_idx  on public.jobs (is_active) where is_active;
create index if not exists jobs_remote_idx  on public.jobs (remote) where remote;
-- Simple full-text search over title + company + location + description.
create index if not exists jobs_fts_idx on public.jobs
  using gin (to_tsvector('english',
    coalesce(title,'') || ' ' || coalesce(company,'') || ' ' ||
    coalesce(location,'') || ' ' || coalesce(description,'')));

alter table public.jobs enable row level security;

-- Anyone (even logged-out) can read active jobs.
drop policy if exists "jobs public read" on public.jobs;
create policy "jobs public read" on public.jobs
  for select using (is_active = true);

grant select on public.jobs to anon, authenticated;

-- keep updated_at fresh on upserts
create or replace function public.jobs_touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end; $$;

drop trigger if exists jobs_touch on public.jobs;
create trigger jobs_touch before update on public.jobs
  for each row execute function public.jobs_touch_updated_at();
