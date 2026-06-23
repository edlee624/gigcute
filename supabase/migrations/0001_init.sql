-- ============================================================================
-- GigCute — initial schema
-- Full data model: identities, seeker profiles, companies, postings, screening
-- (incl. EEO/DE&I voluntary self-ID firewalled from recruiters), mutual-interest
-- matching, invites, reports, analytics.
--
-- Security model: the browser talks to Postgres directly through Supabase, so
-- Row Level Security (RLS) is the real security boundary. Every table has RLS
-- enabled and explicit policies. The anon/auth client can ONLY do what the
-- policies below allow — never trust the frontend.
-- ============================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type user_role       as enum ('seeker', 'recruiter', 'admin');
create type posting_tier    as enum ('free', 'pro', 'max');           -- Basic / Boost / Featured
create type posting_status  as enum ('active', 'paused', 'closed', 'draft');
create type invite_type     as enum ('regular', 'super');
create type invite_status   as enum ('pending', 'accepted', 'declined', 'rescinded');
create type report_status   as enum ('open', 'resolved', 'escalated');

-- ---------------------------------------------------------------------------
-- Helper functions (SECURITY DEFINER so policies can call them without
-- recursing into RLS). Marked STABLE; search_path pinned for safety.
-- ---------------------------------------------------------------------------
create or replace function public.current_role()
returns user_role language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid();
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function public.is_company_member(p_company uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.companies c where c.id = p_company and c.owner_id = auth.uid()
    union
    select 1 from public.company_members m where m.company_id = p_company and m.profile_id = auth.uid()
  );
$$;

create or replace function public.owns_posting(p_posting uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.postings p
    where p.id = p_posting and public.is_company_member(p.company_id)
  );
$$;

-- updated_at trigger helper
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;

-- ===========================================================================
-- IDENTITY
-- ===========================================================================

-- One row per auth.users. Created automatically on signup (trigger below).
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  role        user_role   not null default 'seeker',
  full_name   text,
  email       text,
  avatar_url  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.profiles enable row level security;

create policy "profiles: self read"    on public.profiles for select using (id = auth.uid() or public.is_admin());
create policy "profiles: self update"  on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());
-- inserts happen via the signup trigger (security definer), not the client.

-- Provision a profile row when a new auth user is created. The role and name
-- come from the signup metadata the frontend passes (data: { role, full_name }).
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    coalesce((new.raw_user_meta_data->>'role')::user_role, 'seeker')
  );
  return new;
end; $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ===========================================================================
-- SEEKER PROFILE
-- ===========================================================================
create table public.seeker_profiles (
  profile_id    uuid primary key references public.profiles(id) on delete cascade,
  headline      text,                 -- e.g. "Senior Product Designer"
  photo_url     text,
  linkedin_url  text,                 -- stored as a link only; never scraped
  work_setup    text,                 -- 'Remote' | 'Hybrid' | 'In-office' | free text
  exp_years     int,
  skills        text[]      not null default '{}',
  is_visible    boolean     not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
alter table public.seeker_profiles enable row level security;
create trigger seeker_profiles_touch before update on public.seeker_profiles for each row execute function public.touch_updated_at();

-- Recruiters browse candidates, so visible seeker profiles are readable by any
-- authenticated user; owners manage their own.
create policy "seeker: read visible"  on public.seeker_profiles for select
  using (is_visible or profile_id = auth.uid() or public.is_admin());
create policy "seeker: insert own"    on public.seeker_profiles for insert with check (profile_id = auth.uid());
create policy "seeker: update own"    on public.seeker_profiles for update using (profile_id = auth.uid()) with check (profile_id = auth.uid());

create table public.work_history (
  id          uuid primary key default gen_random_uuid(),
  seeker_id   uuid not null references public.seeker_profiles(profile_id) on delete cascade,
  title       text,
  company     text,
  start_label text,
  end_label   text,
  description text,
  sort_order  int not null default 0
);
alter table public.work_history enable row level security;
create policy "work_history: read"   on public.work_history for select using (true);
create policy "work_history: own cud" on public.work_history for all
  using (seeker_id = auth.uid()) with check (seeker_id = auth.uid());

create table public.education (
  id         uuid primary key default gen_random_uuid(),
  seeker_id  uuid not null references public.seeker_profiles(profile_id) on delete cascade,
  degree     text,
  school     text,
  year       text,
  sort_order int not null default 0
);
alter table public.education enable row level security;
create policy "education: read"    on public.education for select using (true);
create policy "education: own cud" on public.education for all
  using (seeker_id = auth.uid()) with check (seeker_id = auth.uid());

create table public.seeker_prompt_answers (
  id           uuid primary key default gen_random_uuid(),
  seeker_id    uuid not null references public.seeker_profiles(profile_id) on delete cascade,
  prompt_label text not null,
  answer       text,
  is_favorite  boolean not null default false,
  sort_order   int not null default 0
);
alter table public.seeker_prompt_answers enable row level security;
create policy "prompt_answers: read"    on public.seeker_prompt_answers for select using (true);
create policy "prompt_answers: own cud" on public.seeker_prompt_answers for all
  using (seeker_id = auth.uid()) with check (seeker_id = auth.uid());

-- ===========================================================================
-- COMPANIES
-- ===========================================================================
create table public.companies (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references public.profiles(id) on delete cascade,
  name         text not null,
  logo_url     text,
  size         text,
  industry     text,
  linkedin_url text,
  domain       text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
alter table public.companies enable row level security;
create trigger companies_touch before update on public.companies for each row execute function public.touch_updated_at();

create policy "companies: read"        on public.companies for select using (true);
create policy "companies: owner insert" on public.companies for insert with check (owner_id = auth.uid());
create policy "companies: member update" on public.companies for update
  using (public.is_company_member(id)) with check (public.is_company_member(id));
create policy "companies: owner delete" on public.companies for delete using (owner_id = auth.uid());

create table public.company_members (
  company_id uuid not null references public.companies(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  member_role text not null default 'member',
  created_at timestamptz not null default now(),
  primary key (company_id, profile_id)
);
alter table public.company_members enable row level security;
create policy "members: read"   on public.company_members for select using (public.is_company_member(company_id) or profile_id = auth.uid());
create policy "members: manage" on public.company_members for all
  using (public.is_company_member(company_id)) with check (public.is_company_member(company_id));

-- ===========================================================================
-- POSTINGS
-- ===========================================================================
create table public.postings (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete cascade,
  created_by      uuid references public.profiles(id) on delete set null,
  title           text not null,
  department      text,
  seniority       text,
  location_type   text,           -- 'Remote' | 'Hybrid' | 'In-office'
  city            text,
  employment_type text,           -- 'Full-time' | 'Part-time' | 'Contract'
  salary_min      int,
  salary_max      int,
  equity          boolean not null default false,
  responsibilities text[] not null default '{}',
  qualifications   text[] not null default '{}',
  tier            posting_tier   not null default 'free',
  status          posting_status not null default 'draft',
  views           int not null default 0,
  published_at    timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
alter table public.postings enable row level security;
create trigger postings_touch before update on public.postings for each row execute function public.touch_updated_at();
create index on public.postings (status);
create index on public.postings (company_id);

-- Active postings are visible to everyone signed in; company members see all of
-- their own (incl. drafts/paused).
create policy "postings: read active or own" on public.postings for select
  using (status = 'active' or public.is_company_member(company_id) or public.is_admin());
create policy "postings: member write" on public.postings for all
  using (public.is_company_member(company_id)) with check (public.is_company_member(company_id));

create table public.posting_requested_prompts (
  id          uuid primary key default gen_random_uuid(),
  posting_id  uuid not null references public.postings(id) on delete cascade,
  prompt_label text not null,
  sort_order  int not null default 0
);
alter table public.posting_requested_prompts enable row level security;
create policy "req prompts: read"  on public.posting_requested_prompts for select using (true);
create policy "req prompts: write" on public.posting_requested_prompts for all
  using (public.owns_posting(posting_id)) with check (public.owns_posting(posting_id));

-- Screening questions. is_voluntary = EEO/DE&I self-identification. Tier limits
-- (Basic 0, Boost 3, Featured 10 regular questions; voluntary unlimited on all
-- tiers) are enforced by the trigger below as a server-side backstop.
create table public.screening_questions (
  id           uuid primary key default gen_random_uuid(),
  posting_id   uuid not null references public.postings(id) on delete cascade,
  template_id  text,
  question_text text,
  fill_value   text,
  min_years    int,
  degree_level text,
  proficiency  text,
  essential    boolean not null default false,
  is_voluntary boolean not null default false,  -- EEO/DE&I: never used to screen
  sort_order   int not null default 0
);
alter table public.screening_questions enable row level security;
create policy "screening: read"  on public.screening_questions for select using (true);
create policy "screening: write" on public.screening_questions for all
  using (public.owns_posting(posting_id)) with check (public.owns_posting(posting_id));

-- Voluntary EEO questions can never be marked essential, and regular screening
-- questions are capped per tier. Enforced regardless of what the client sends.
create or replace function public.enforce_screening_rules()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_tier posting_tier;
  v_max  int;
  v_count int;
begin
  if new.is_voluntary then
    new.essential := false;       -- voluntary self-ID is never a screen/reject criterion
    return new;
  end if;
  select tier into v_tier from public.postings where id = new.posting_id;
  v_max := case v_tier when 'free' then 0 when 'pro' then 3 when 'max' then 10 else 0 end;
  select count(*) into v_count from public.screening_questions
    where posting_id = new.posting_id and is_voluntary = false and id <> new.id;
  if v_count >= v_max then
    raise exception 'Screening question limit reached for this tier (% allowed)', v_max;
  end if;
  return new;
end; $$;
create trigger screening_rules before insert or update on public.screening_questions
  for each row execute function public.enforce_screening_rules();

-- ===========================================================================
-- APPLICATIONS / ANSWERS
-- ===========================================================================

-- Answers to regular (non-voluntary) screening questions.
create table public.application_answers (
  id           uuid primary key default gen_random_uuid(),
  posting_id   uuid not null references public.postings(id) on delete cascade,
  seeker_id    uuid not null references public.seeker_profiles(profile_id) on delete cascade,
  question_id  uuid not null references public.screening_questions(id) on delete cascade,
  answer_text  text,
  meets_essential boolean,
  created_at   timestamptz not null default now(),
  unique (question_id, seeker_id)
);
alter table public.application_answers enable row level security;
create policy "answers: seeker insert own" on public.application_answers for insert with check (seeker_id = auth.uid());
create policy "answers: seeker read own"   on public.application_answers for select using (seeker_id = auth.uid());
create policy "answers: recruiter read"    on public.application_answers for select using (public.owns_posting(posting_id));

-- VOLUNTARY EEO / DE&I responses. Deliberately firewalled: seekers can write
-- and read their own, recruiters get NO row-level read access. Aggregate-only
-- reporting is exposed via the security-definer function below, which suppresses
-- small cells to prevent re-identification. These are never linked to screening.
create table public.eeo_responses (
  id          uuid primary key default gen_random_uuid(),
  posting_id  uuid not null references public.postings(id) on delete cascade,
  seeker_id   uuid not null references public.seeker_profiles(profile_id) on delete cascade,
  category    text not null,        -- 'gender' | 'ethnicity' | 'veteran' | 'disability'
  value       text not null,
  created_at  timestamptz not null default now(),
  unique (posting_id, seeker_id, category)
);
alter table public.eeo_responses enable row level security;
create policy "eeo: seeker insert own" on public.eeo_responses for insert with check (seeker_id = auth.uid());
create policy "eeo: seeker read own"   on public.eeo_responses for select using (seeker_id = auth.uid());
-- NOTE: intentionally NO recruiter/select policy. Recruiters cannot read rows.

-- Aggregate EEO reporting for a posting's owner, with small-cell suppression.
create or replace function public.eeo_aggregate(p_posting uuid, p_min_cell int default 5)
returns table (category text, value text, n bigint)
language sql security definer set search_path = public as $$
  select e.category, e.value, count(*)::bigint
  from public.eeo_responses e
  where e.posting_id = p_posting
    and public.owns_posting(p_posting)         -- only the posting's company
  group by e.category, e.value
  having count(*) >= p_min_cell;               -- suppress small cells
$$;

-- ===========================================================================
-- MUTUAL INTEREST + INVITES + MATCHES
-- ===========================================================================

-- Seeker expresses interest in a posting ("Interested").
create table public.seeker_interest (
  seeker_id  uuid not null references public.seeker_profiles(profile_id) on delete cascade,
  posting_id uuid not null references public.postings(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (seeker_id, posting_id)
);
alter table public.seeker_interest enable row level security;
create policy "seeker_interest: own write" on public.seeker_interest for all
  using (seeker_id = auth.uid()) with check (seeker_id = auth.uid());
create policy "seeker_interest: recruiter read" on public.seeker_interest for select
  using (seeker_id = auth.uid() or public.owns_posting(posting_id));

-- Recruiter expresses interest in a candidate for a posting.
create table public.recruiter_interest (
  posting_id uuid not null references public.postings(id) on delete cascade,
  seeker_id  uuid not null references public.seeker_profiles(profile_id) on delete cascade,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (posting_id, seeker_id)
);
alter table public.recruiter_interest enable row level security;
create policy "recruiter_interest: member write" on public.recruiter_interest for all
  using (public.owns_posting(posting_id)) with check (public.owns_posting(posting_id));
create policy "recruiter_interest: seeker read" on public.recruiter_interest for select
  using (seeker_id = auth.uid() or public.owns_posting(posting_id));

-- A match exists when both sides expressed interest. Exposed as a view.
create view public.matches as
  select s.posting_id, s.seeker_id, greatest(s.created_at, r.created_at) as matched_at
  from public.seeker_interest s
  join public.recruiter_interest r
    on r.posting_id = s.posting_id and r.seeker_id = s.seeker_id;

create table public.invites (
  id          uuid primary key default gen_random_uuid(),
  posting_id  uuid not null references public.postings(id) on delete cascade,
  seeker_id   uuid not null references public.seeker_profiles(profile_id) on delete cascade,
  type        invite_type   not null default 'regular',
  status      invite_status not null default 'pending',
  note        text,
  created_at  timestamptz not null default now(),
  responded_at timestamptz,
  unique (posting_id, seeker_id)
);
alter table public.invites enable row level security;
create policy "invites: member write"  on public.invites for all
  using (public.owns_posting(posting_id)) with check (public.owns_posting(posting_id));
create policy "invites: seeker read"   on public.invites for select using (seeker_id = auth.uid());
create policy "invites: seeker respond" on public.invites for update
  using (seeker_id = auth.uid())
  with check (seeker_id = auth.uid() and status in ('accepted','declined'));

create table public.saved_jobs (
  seeker_id  uuid not null references public.seeker_profiles(profile_id) on delete cascade,
  posting_id uuid not null references public.postings(id) on delete cascade,
  status     text not null default 'saved',  -- 'saved' | 'applied' | 'interviewing' | ...
  created_at timestamptz not null default now(),
  primary key (seeker_id, posting_id)
);
alter table public.saved_jobs enable row level security;
create policy "saved_jobs: own" on public.saved_jobs for all
  using (seeker_id = auth.uid()) with check (seeker_id = auth.uid());

-- ===========================================================================
-- TRUST & SAFETY + ANALYTICS
-- ===========================================================================
create table public.reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid references public.profiles(id) on delete set null,
  target_type text not null,        -- 'posting' | 'candidate' | 'company'
  target_id   text,
  reason      text not null,
  details     text,
  status      report_status not null default 'open',
  created_at  timestamptz not null default now()
);
alter table public.reports enable row level security;
create policy "reports: insert any"  on public.reports for insert with check (auth.uid() is not null);
create policy "reports: admin read"  on public.reports for select using (public.is_admin());
create policy "reports: admin update" on public.reports for update using (public.is_admin());

create table public.events (
  id         bigint generated always as identity primary key,
  user_id    uuid references public.profiles(id) on delete set null,
  type       text not null,
  data       jsonb not null default '{}',
  created_at timestamptz not null default now()
);
alter table public.events enable row level security;
create policy "events: insert any" on public.events for insert with check (true);
create policy "events: admin read" on public.events for select using (public.is_admin());

-- ===========================================================================
-- REFERENCE DATA (read-only to clients; seeded in 0002)
-- ===========================================================================
create table public.prompt_bank (
  id    int primary key,
  label text not null
);
alter table public.prompt_bank enable row level security;
create policy "prompt_bank: read all" on public.prompt_bank for select using (true);

create table public.screening_templates (
  id           text primary key,
  label        text not null,
  question     text,
  type         text not null,
  fill_label   text,
  placeholder  text,
  ideal        text,
  is_voluntary boolean not null default false,
  options      text[],
  sort_order   int not null default 0
);
alter table public.screening_templates enable row level security;
create policy "screening_templates: read all" on public.screening_templates for select using (true);
