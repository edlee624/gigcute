-- ============================================================================
-- GigCute ATS — Phase 1: the pipeline core.
--
-- Turns interest + postings into a real hiring pipeline. Four tables, all
-- company-scoped by RLS (via is_company_member = owner OR company_members):
--   job_stages             ordered pipeline per posting (seeded on create)
--   applications           one candidate on one job — the pipeline card
--   application_activities  append-only timeline / audit
--   scorecards             structured interview feedback
--
-- Existing seeker_interest (candidate applied) and recruiter_interest (recruiter
-- sourced) backfill into applications. Candidates = GigCute seekers for now.
-- ============================================================================

-- ---- enums ----
do $$ begin create type application_status as enum ('active','hired','rejected','withdrawn'); exception when duplicate_object then null; end $$;
do $$ begin create type application_source as enum ('applied','sourced','referral','import'); exception when duplicate_object then null; end $$;
do $$ begin create type stage_category    as enum ('applied','screen','interview','offer','hired'); exception when duplicate_object then null; end $$;
do $$ begin create type scorecard_verdict as enum ('strong_yes','yes','mixed','no','strong_no'); exception when duplicate_object then null; end $$;
do $$ begin create type ats_activity_type as enum ('created','stage_change','note','email','scorecard','rejected','hired','withdrawn'); exception when duplicate_object then null; end $$;

-- ---- tables ----
create table if not exists public.job_stages (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  posting_id uuid not null references public.postings(id) on delete cascade,
  name text not null,
  sort_order int not null default 0,
  category stage_category not null,
  created_at timestamptz not null default now()
);
create index if not exists job_stages_posting_idx on public.job_stages(posting_id, sort_order);

create table if not exists public.applications (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  posting_id uuid not null references public.postings(id) on delete cascade,
  candidate_id uuid not null references public.profiles(id) on delete cascade,
  current_stage_id uuid references public.job_stages(id) on delete set null,
  status application_status not null default 'active',
  source application_source not null default 'applied',
  rejected_reason text,
  rejected_at timestamptz,
  applied_at timestamptz not null default now(),
  created_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now(),
  unique (posting_id, candidate_id)
);
create index if not exists applications_posting_idx   on public.applications(posting_id, status);
create index if not exists applications_stage_idx     on public.applications(current_stage_id);
create index if not exists applications_candidate_idx on public.applications(candidate_id);

create table if not exists public.application_activities (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  type ats_activity_type not null,
  from_stage_id uuid references public.job_stages(id) on delete set null,
  to_stage_id uuid references public.job_stages(id) on delete set null,
  body text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists app_activities_app_idx on public.application_activities(application_id, created_at desc);

create table if not exists public.scorecards (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  stage_id uuid references public.job_stages(id) on delete set null,
  interviewer_id uuid not null references public.profiles(id) on delete cascade,
  overall scorecard_verdict not null,
  summary text,
  ratings jsonb not null default '{}'::jsonb,
  submitted_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists scorecards_app_idx on public.scorecards(application_id);

-- ---- updated_at + created-activity triggers ----
create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
drop trigger if exists applications_touch on public.applications;
create trigger applications_touch before update on public.applications
  for each row execute function public.touch_updated_at();

-- Log a 'created' activity for every new application (fires during backfill too).
create or replace function public.ats_log_created() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  insert into public.application_activities(company_id, application_id, actor_id, type, to_stage_id, body)
  values (new.company_id, new.id, coalesce(new.created_by, auth.uid()), 'created', new.current_stage_id,
          case new.source when 'sourced' then 'Sourced' when 'referral' then 'Referred'
                          when 'import' then 'Imported' else 'Applied' end);
  return new;
end $$;
drop trigger if exists applications_log_created on public.applications;
create trigger applications_log_created after insert on public.applications
  for each row execute function public.ats_log_created();

-- ---- default stage seeding ----
create or replace function public.seed_default_stages(p_posting uuid, p_company uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if exists (select 1 from public.job_stages where posting_id = p_posting) then return; end if;
  insert into public.job_stages(company_id, posting_id, name, sort_order, category) values
    (p_company, p_posting, 'Applied',   1, 'applied'),
    (p_company, p_posting, 'Screen',    2, 'screen'),
    (p_company, p_posting, 'Interview', 3, 'interview'),
    (p_company, p_posting, 'Offer',     4, 'offer'),
    (p_company, p_posting, 'Hired',     5, 'hired');
end $$;

create or replace function public.postings_seed_stages() returns trigger
language plpgsql security definer set search_path=public as $$
begin perform public.seed_default_stages(new.id, new.company_id); return new; end $$;
drop trigger if exists postings_seed_stages_trg on public.postings;
create trigger postings_seed_stages_trg after insert on public.postings
  for each row execute function public.postings_seed_stages();

-- seed stages for postings that already exist
do $$ declare r record; begin
  for r in select id, company_id from public.postings loop
    perform public.seed_default_stages(r.id, r.company_id);
  end loop;
end $$;

-- ---- RLS ----
alter table public.job_stages             enable row level security;
alter table public.applications           enable row level security;
alter table public.application_activities enable row level security;
alter table public.scorecards             enable row level security;

revoke all on public.job_stages, public.applications, public.application_activities, public.scorecards from anon;
grant select, insert, update, delete on public.job_stages, public.applications, public.application_activities, public.scorecards to authenticated;

drop policy if exists job_stages_member on public.job_stages;
create policy job_stages_member on public.job_stages for all
  using (public.is_company_member(company_id)) with check (public.is_company_member(company_id));

drop policy if exists applications_member on public.applications;
create policy applications_member on public.applications for all
  using (public.is_company_member(company_id)) with check (public.is_company_member(company_id));
drop policy if exists applications_candidate_read on public.applications;
create policy applications_candidate_read on public.applications for select
  using (candidate_id = auth.uid());

drop policy if exists app_activities_member on public.application_activities;
create policy app_activities_member on public.application_activities for all
  using (public.is_company_member(company_id)) with check (public.is_company_member(company_id));

drop policy if exists scorecards_member on public.scorecards;
create policy scorecards_member on public.scorecards for all
  using (public.is_company_member(company_id)) with check (public.is_company_member(company_id));

-- ---- backfill applications from existing interest ----
insert into public.applications (company_id, posting_id, candidate_id, current_stage_id, status, source, applied_at)
select p.company_id, si.posting_id, si.seeker_id,
       (select id from public.job_stages s where s.posting_id = si.posting_id and s.category='applied' limit 1),
       'active', 'applied', si.created_at
from public.seeker_interest si
join public.postings p on p.id = si.posting_id
on conflict (posting_id, candidate_id) do nothing;

insert into public.applications (company_id, posting_id, candidate_id, current_stage_id, status, source, applied_at, created_by)
select p.company_id, ri.posting_id, ri.seeker_id,
       (select id from public.job_stages s where s.posting_id = ri.posting_id and s.category='applied' limit 1),
       'active', 'sourced', ri.created_at, ri.created_by
from public.recruiter_interest ri
join public.postings p on p.id = ri.posting_id
on conflict (posting_id, candidate_id) do nothing;
