-- ============================================================================
-- GigCute — tracked_jobs (personal job tracker for the aggregated feed)
-- Each user can Save jobs from the /jobs feed and mark them Applied. Stores a
-- snapshot (title/company/url) so the tracker survives even if the underlying
-- feed job is re-ingested or removed. Private to each user.
-- NOTE: named tracked_jobs (not saved_jobs) — public.saved_jobs already exists
-- from 0001 for a different purpose (seekers saving recruiter POSTINGS).
-- ============================================================================
create table if not exists public.tracked_jobs (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  job_id     uuid references public.jobs(id) on delete set null,
  status     text not null default 'saved' check (status in ('saved','applied','dismissed')),
  title      text not null,
  company    text,
  location   text,
  url        text,
  applied_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, job_id)
);
alter table public.tracked_jobs enable row level security;
create index if not exists tracked_jobs_user_idx on public.tracked_jobs (user_id, updated_at desc);

drop policy if exists "tracked_jobs: own" on public.tracked_jobs;
create policy "tracked_jobs: own" on public.tracked_jobs for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select, insert, update, delete on public.tracked_jobs to authenticated;

drop trigger if exists tracked_jobs_touch on public.tracked_jobs;
create trigger tracked_jobs_touch before update on public.tracked_jobs
  for each row execute function public.touch_updated_at();
