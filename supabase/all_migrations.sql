-- GigCute — all migrations combined (run once in the Supabase SQL editor).
-- ==== FILE: 0001_init.sql ====
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

-- Helper functions below are defined before the tables they reference (so RLS
-- policies created alongside each table can call them). Defer body validation
-- until call time so these forward references don't error at creation.
set check_function_bodies = off;

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

-- ==== FILE: 0002_reference_data.sql ====
-- ============================================================================
-- GigCute — reference data
-- The shared prompt bank and screening-question templates (incl. the voluntary
-- EEO / DE&I self-identification templates). These mirror the constants the
-- frontend currently hard-codes; once seeded, the app can read them from here.
-- ============================================================================

insert into public.prompt_bank (id, label) values
  (1,  'My superpower at work'),
  (2,  'I''m proudest of'),
  (3,  'Looking for a team that'),
  (4,  'A mistake that taught me the most'),
  (5,  'My ideal manager'),
  (6,  'Outside of work, I'),
  (7,  'The tool I can''t live without'),
  (8,  'On a typical Tuesday, I'),
  (9,  'I work best when'),
  (10, 'The skill I''m still building'),
  (11, 'A project I''d love to talk about'),
  (12, 'My non-negotiable'),
  (13, 'I geek out about'),
  (14, 'The feedback that changed how I work'),
  (15, 'My biggest career pivot'),
  (16, 'I''m the person people come to for'),
  (17, 'A risk that paid off'),
  (18, 'What gets me out of bed in the morning'),
  (19, 'My work style in three words'),
  (20, 'The hardest thing I''ve shipped'),
  (21, 'I learn best by'),
  (22, 'A belief I''ve changed my mind on'),
  (23, 'The kind of problems I want to solve next'),
  (24, 'My favorite part of the day'),
  (25, 'I''m currently learning'),
  (26, 'A team I''d love to be part of'),
  (27, 'What success looks like to me'),
  (28, 'The thing I wish more interviewers asked me'),
  (29, 'My pet peeve at work'),
  (30, 'Two truths and a lie about my work style')
on conflict (id) do nothing;

-- Regular screening templates (tier-limited) ---------------------------------
insert into public.screening_templates (id, label, question, type, fill_label, placeholder, ideal, is_voluntary, sort_order) values
  ('background-check', 'Background Check',     'Are you willing to undergo a background check, in accordance with local law/regulations?', 'yesno', null, null, 'Yes', false, 1),
  ('certifications',   'Certifications',       'Do you have the following license or certification?', 'fill-yesno', 'License / Certification', 'e.g. PMP, AWS Solutions Architect', 'Yes', false, 2),
  ('drivers-license',  'Driver''s License',    'Do you have a valid driver''s license?', 'yesno', null, null, 'Yes', false, 3),
  ('drug-test',        'Drug Test',            'Are you willing to take a drug test, in accordance with local law/regulations?', 'yesno', null, null, 'Yes', false, 4),
  ('education',        'Education',            'Have you completed the following level of education?', 'education', null, null, 'Yes', false, 5),
  ('skill-exp',        'Expertise with Skill', 'How many years of work experience do you have with [Skill]?', 'fill-minyears', 'Skill', 'e.g. Python, Figma, SQL', null, false, 6),
  ('gpa',              'GPA',                  'What is your university grade point average (4.0 GPA Scale)?', 'min-number', 'Minimum GPA', 'e.g. 3.0', null, false, 7),
  ('hybrid-work',      'Hybrid Work',          'Are you comfortable working in a hybrid setting?', 'yesno', null, null, 'Yes', false, 8),
  ('industry-exp',     'Industry Experience',  'How many years of [Industry] experience do you currently have?', 'fill-minyears', 'Industry', 'e.g. Healthcare, Fintech, SaaS', null, false, 9),
  ('language',         'Language',             'What is your level of proficiency in [Language]?', 'language', 'Language', 'e.g. Spanish, Mandarin', null, false, 10),
  ('location',         'Location',             'Are you comfortable commuting to this job''s location?', 'yesno', null, null, 'Yes', false, 11),
  ('onsite-work',      'Onsite Work',          'Are you comfortable working in an onsite setting?', 'yesno', null, null, 'Yes', false, 12),
  ('remote-work',      'Remote Work',          'Are you comfortable working in a remote setting?', 'yesno', null, null, 'Yes', false, 13),
  ('urgent-hiring',    'Urgent Hiring Need',   '', 'custom', null, 'Describe your urgent hiring requirement…', null, false, 14),
  ('visa-status',      'Visa Status',          'Will you now, or in the future, require sponsorship for employment visa status (e.g. H-1B)?', 'yesno', null, null, 'No', false, 15),
  ('work-auth',        'Work Authorization',   'Are you legally authorized to work in the United States?', 'yesno', null, null, 'Yes', false, 16),
  ('job-function-exp', 'Work Experience',      'How many years of [Job Function] experience do you currently have?', 'fill-minyears', 'Job Function', 'e.g. Product Management, Engineering', null, false, 17),
  ('custom',           'Custom Question',      '', 'custom', null, 'Write your own screening question…', null, false, 18)
on conflict (id) do nothing;

-- Voluntary self-identification (EEO / DE&I) templates -----------------------
-- Available on every tier; never used to screen, rank, or reject.
insert into public.screening_templates (id, label, question, type, is_voluntary, options, sort_order) values
  ('eeo-gender',     'Gender',            'How do you describe your gender identity? (Voluntary)',                  'voluntary', true,
    array['Man','Woman','Non-binary','Prefer to self-describe','Decline to self-identify'], 100),
  ('eeo-ethnicity',  'Race / Ethnicity',  'Which race or ethnicity best describes you? (Voluntary)',                'voluntary', true,
    array['Hispanic or Latino','White','Black or African American','Asian','Native American or Alaska Native','Native Hawaiian or Other Pacific Islander','Two or more races','Decline to self-identify'], 101),
  ('eeo-veteran',    'Veteran Status',    'Do you identify as a protected veteran? (Voluntary)',                    'voluntary', true,
    array['I am a protected veteran','I am not a protected veteran','Decline to self-identify'], 102),
  ('eeo-disability', 'Disability Status', 'Do you have a disability, or have you had one in the past? (Voluntary)', 'voluntary', true,
    array['Yes','No','Decline to self-identify'], 103)
on conflict (id) do nothing;

-- ==== FILE: 0003_storage.sql ====
-- ============================================================================
-- GigCute — storage
-- A single public 'media' bucket holds avatars and company logos. Files live
-- under <kind>/<user-id>/<filename>, e.g. avatars/<uid>/... and logos/<uid>/...
--
-- Public read (so photo_url / logo_url resolve in the browser); authenticated
-- users can only write/replace/delete files in their own <uid> folder.
-- ============================================================================

insert into storage.buckets (id, name, public)
values ('media', 'media', true)
on conflict (id) do nothing;

-- Anyone can read media (URLs are public).
create policy "media: public read"
  on storage.objects for select
  using (bucket_id = 'media');

-- Authenticated users may upload only into a folder named after their own uid
-- (the second path segment: avatars/<uid>/file or logos/<uid>/file).
create policy "media: owner insert"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and (storage.foldername(name))[2] = auth.uid()::text);

create policy "media: owner update"
  on storage.objects for update to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[2] = auth.uid()::text);

create policy "media: owner delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[2] = auth.uid()::text);

-- ==== FILE: 0004_recruiter_verification.sql ====
-- ============================================================================
-- GigCute — recruiter verification
-- Goal: stop fake recruiter/company accounts from reaching candidate data.
--
-- Model:
--   * A company is auto-verified when its owner's email is on a real business
--     domain (not a free/personal or disposable provider). Free/disposable
--     domains -> verified=false, pending manual admin review.
--   * Clients can NEVER set/raise `verified` themselves (trigger enforces it);
--     only the insert logic or an admin can.
--   * Candidate PII (seeker profiles + work history + education + prompt answers,
--     and who-is-interested lists) is readable by recruiters ONLY when they
--     belong to a verified company. Email-confirmation (Supabase) still gates
--     account activation on top of this.
-- ============================================================================

-- ---- Free / disposable email-domain blocklist -----------------------------
create table public.blocked_email_domains (
  domain text primary key
);
alter table public.blocked_email_domains enable row level security;
create policy "blocked domains: read all" on public.blocked_email_domains for select using (true);

insert into public.blocked_email_domains (domain) values
  -- free / personal providers
  ('gmail.com'),('googlemail.com'),('yahoo.com'),('ymail.com'),('outlook.com'),('hotmail.com'),
  ('live.com'),('msn.com'),('icloud.com'),('me.com'),('mac.com'),('aol.com'),('gmx.com'),('gmx.net'),
  ('mail.com'),('proton.me'),('protonmail.com'),('pm.me'),('yandex.com'),('yandex.ru'),('zoho.com'),
  ('fastmail.com'),('hey.com'),('tutanota.com'),('hotmail.co.uk'),('yahoo.co.uk'),('comcast.net'),('verizon.net'),
  -- disposable / throwaway
  ('mailinator.com'),('tempmail.com'),('temp-mail.org'),('guerrillamail.com'),('10minutemail.com'),
  ('throwaway.email'),('trashmail.com'),('getnada.com'),('dispostable.com'),('yopmail.com'),
  ('sharklasers.com'),('tempmail.io'),('maildrop.cc'),('mintemail.com'),('fakeinbox.com'),('emailondeck.com')
on conflict (domain) do nothing;

-- ---- Company verification columns -----------------------------------------
alter table public.companies
  add column if not exists verified     boolean not null default false,
  add column if not exists verified_at  timestamptz,
  add column if not exists email_domain text;

-- ---- Helpers ---------------------------------------------------------------
-- A business domain is one that is present and NOT on the blocklist.
create or replace function public.is_business_domain(p_domain text)
returns boolean language sql stable security definer set search_path = public as $$
  select p_domain is not null and p_domain <> ''
     and not exists (select 1 from public.blocked_email_domains b where b.domain = lower(p_domain));
$$;

-- Is the current user a member/owner of at least one VERIFIED company?
create or replace function public.is_verified_recruiter()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.companies c
    where c.verified = true
      and ( c.owner_id = auth.uid()
            or exists (select 1 from public.company_members m
                       where m.company_id = c.id and m.profile_id = auth.uid()) )
  );
$$;

-- ---- Verification trigger (the backstop) ----------------------------------
-- On INSERT: derive the owner's email domain and auto-verify business domains.
-- On UPDATE: non-admins cannot change verified/verified_at/email_domain.
create or replace function public.guard_company_verification()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_email text; v_domain text;
begin
  if tg_op = 'INSERT' then
    select email into v_email from auth.users where id = new.owner_id;
    v_domain := lower(split_part(coalesce(v_email, ''), '@', 2));
    new.email_domain := v_domain;
    new.verified := public.is_business_domain(v_domain);
    new.verified_at := case when new.verified then now() else null end;
  else
    if not public.is_admin() then
      new.verified     := old.verified;
      new.verified_at  := old.verified_at;
      new.email_domain := old.email_domain;
    end if;
  end if;
  return new;
end; $$;

create trigger company_verification
  before insert or update on public.companies
  for each row execute function public.guard_company_verification();

-- Admin manual verification (for legit recruiters on personal email, appeals).
create or replace function public.admin_set_company_verified(p_company uuid, p_verified boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not authorized'; end if;
  update public.companies
    set verified = p_verified, verified_at = case when p_verified then now() else null end
    where id = p_company;
end; $$;

-- ---- Gate candidate PII behind verified-recruiter status -------------------
-- Replace the permissive read policies from 0001 so candidate data is only
-- visible to the candidate themselves, a VERIFIED recruiter, or an admin.
drop policy if exists "seeker: read visible" on public.seeker_profiles;
create policy "seeker: read gated" on public.seeker_profiles for select
  using (profile_id = auth.uid() or public.is_verified_recruiter() or public.is_admin());

drop policy if exists "work_history: read" on public.work_history;
create policy "work_history: read gated" on public.work_history for select
  using (seeker_id = auth.uid() or public.is_verified_recruiter() or public.is_admin());

drop policy if exists "education: read" on public.education;
create policy "education: read gated" on public.education for select
  using (seeker_id = auth.uid() or public.is_verified_recruiter() or public.is_admin());

drop policy if exists "prompt_answers: read" on public.seeker_prompt_answers;
create policy "prompt_answers: read gated" on public.seeker_prompt_answers for select
  using (seeker_id = auth.uid() or public.is_verified_recruiter() or public.is_admin());

-- Who-is-interested lists also require a verified recruiter.
drop policy if exists "seeker_interest: recruiter read" on public.seeker_interest;
create policy "seeker_interest: recruiter read" on public.seeker_interest for select
  using (seeker_id = auth.uid() or (public.owns_posting(posting_id) and public.is_verified_recruiter()));

-- ==== FILE: 0005_id_verification.sql ====
-- ============================================================================
-- GigCute — recruiter ID verification (for personal/flagged emails)
-- A recruiter on a personal email can upload one photo of themselves holding
-- their government ID. This is SENSITIVE: it goes in a PRIVATE bucket (no public
-- read) and is reviewable only by the uploader and admins. An admin approves the
-- request, which then verifies the company (admin_set_company_verified).
-- ============================================================================

-- Private bucket for verification photos (note: public = false).
insert into storage.buckets (id, name, public)
values ('verification', 'verification', false)
on conflict (id) do nothing;

-- Files live at verification/<uid>/<filename>. Only the owner can upload, and
-- only the owner or an admin can read. No public read policy exists.
create policy "verif: owner insert"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'verification' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "verif: owner or admin read"
  on storage.objects for select to authenticated
  using (bucket_id = 'verification' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

create policy "verif: owner delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'verification' and (storage.foldername(name))[1] = auth.uid()::text);

-- Verification requests (admin review queue).
create table public.verification_requests (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid not null references public.profiles(id) on delete cascade,
  company_id  uuid references public.companies(id) on delete set null,
  doc_path    text not null,
  status      text not null default 'pending',   -- pending | approved | rejected
  note        text,
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at  timestamptz not null default now()
);
alter table public.verification_requests enable row level security;

create policy "verif req: owner insert" on public.verification_requests for insert
  with check (profile_id = auth.uid());
create policy "verif req: owner/admin read" on public.verification_requests for select
  using (profile_id = auth.uid() or public.is_admin());
create policy "verif req: admin update" on public.verification_requests for update
  using (public.is_admin());

-- Admin: approve a verification request and verify its company in one step.
create or replace function public.admin_review_verification(p_request uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_company uuid;
begin
  if not public.is_admin() then raise exception 'not authorized'; end if;
  update public.verification_requests
    set status = case when p_approve then 'approved' else 'rejected' end,
        note = p_note, reviewed_by = auth.uid(), reviewed_at = now()
    where id = p_request
    returning company_id into v_company;
  if p_approve and v_company is not null then
    perform public.admin_set_company_verified(v_company, true);
  end if;
end; $$;

-- ==== FILE: 0006_grants.sql ====
-- ============================================================================
-- GigCute — role grants
-- Supabase's anon/authenticated roles need table/function privileges IN ADDITION
-- to the RLS policies. (When the schema is created via the SQL editor these
-- default grants aren't always applied.) RLS still governs which ROWS are
-- visible; these GRANTs just allow the roles to touch the tables at all.
-- ============================================================================

grant usage on schema public to anon, authenticated, service_role;

grant select, insert, update, delete on all tables in schema public to anon, authenticated, service_role;
grant usage, select on all sequences in schema public to anon, authenticated, service_role;
grant execute on all functions in schema public to anon, authenticated, service_role;

-- Apply the same to anything created later.
alter default privileges in schema public grant select, insert, update, delete on tables to anon, authenticated, service_role;
alter default privileges in schema public grant usage, select on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;

-- ==== FILE: 0007_role_security.sql ====
-- ============================================================================
-- GigCute — role security hardening
-- Closes two privilege-escalation paths around the admin role:
--   1) Signup metadata could request role='admin' (handle_new_user trusted it).
--   2) The profiles self-update policy let a user change their own role.
-- After this, 'admin' can only be granted server-side (SQL editor / service_role)
-- or by an existing admin — never by a normal user or at signup.
-- ============================================================================

-- 1) Never accept 'admin' (or invalid) role from signup metadata.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_role user_role;
begin
  begin
    v_role := (new.raw_user_meta_data->>'role')::user_role;
  exception when others then
    v_role := 'seeker';
  end;
  if v_role is null or v_role = 'admin' then
    v_role := 'seeker';
  end if;
  insert into public.profiles (id, email, full_name, role)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name',''), v_role);
  return new;
end; $$;

-- 2) Prevent non-admins from changing their own role via UPDATE.
--    auth.uid() is null for server-side / SQL-editor / service_role calls, so
--    bootstrapping the first admin via the SQL editor still works.
create or replace function public.guard_profile_role()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.role is distinct from old.role then
    if not (public.is_admin() or auth.uid() is null) then
      new.role := old.role;   -- silently ignore unauthorized role changes
    end if;
  end if;
  return new;
end; $$;

drop trigger if exists profile_role_guard on public.profiles;
create trigger profile_role_guard
  before update on public.profiles
  for each row execute function public.guard_profile_role();

-- ==== FILE: 0008_chat.sql ====
-- ============================================================================
-- GigCute — chat / messaging
-- A conversation exists per (posting, seeker) and only opens once the connection
-- is mutual: either a match (both expressed interest) or an accepted invite —
-- "the conversation begins when both say yes". Participants are the seeker and
-- the posting's company members. Realtime delivers new messages live.
-- ============================================================================

-- Is there an open connection between this posting and seeker?
create or replace function public.connection_open(p_posting uuid, p_seeker uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.matches m where m.posting_id = p_posting and m.seeker_id = p_seeker)
      or exists (select 1 from public.invites i where i.posting_id = p_posting and i.seeker_id = p_seeker and i.status = 'accepted');
$$;

create table public.conversations (
  id              uuid primary key default gen_random_uuid(),
  posting_id      uuid not null references public.postings(id) on delete cascade,
  seeker_id       uuid not null references public.seeker_profiles(profile_id) on delete cascade,
  created_at      timestamptz not null default now(),
  last_message_at timestamptz not null default now(),
  unique (posting_id, seeker_id)
);
alter table public.conversations enable row level security;
create index on public.conversations (seeker_id);
create index on public.conversations (posting_id);

create policy "conv: participants read" on public.conversations for select
  using (seeker_id = auth.uid() or public.owns_posting(posting_id) or public.is_admin());
create policy "conv: open connection insert" on public.conversations for insert
  with check ((seeker_id = auth.uid() or public.owns_posting(posting_id)) and public.connection_open(posting_id, seeker_id));
create policy "conv: participants update" on public.conversations for update
  using (seeker_id = auth.uid() or public.owns_posting(posting_id));

-- Can the current user access this conversation? (used by message policies)
create or replace function public.can_access_conversation(p_conv uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.conversations c
    where c.id = p_conv
      and (c.seeker_id = auth.uid() or public.owns_posting(c.posting_id) or public.is_admin())
  );
$$;

create table public.messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id       uuid references public.profiles(id) on delete set null,
  body            text not null,
  created_at      timestamptz not null default now(),
  read_at         timestamptz
);
alter table public.messages enable row level security;
create index on public.messages (conversation_id, created_at);

create policy "msg: participants read" on public.messages for select
  using (public.can_access_conversation(conversation_id));
create policy "msg: sender insert" on public.messages for insert
  with check (sender_id = auth.uid() and public.can_access_conversation(conversation_id));
create policy "msg: recipient mark read" on public.messages for update
  using (public.can_access_conversation(conversation_id));

-- Bump the conversation's last_message_at on every new message (for sort/preview).
create or replace function public.touch_conversation()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.conversations set last_message_at = now() where id = new.conversation_id;
  return new;
end; $$;
create trigger messages_touch_conv after insert on public.messages
  for each row execute function public.touch_conversation();

-- Realtime: stream inserts to subscribed participants (filtered by RLS).
alter publication supabase_realtime add table public.messages;
alter publication supabase_realtime add table public.conversations;

-- ==== FILE: 0009_support_feedback.sql ====
-- ============================================================================
-- GigCute — support tickets + chat feedback
-- ============================================================================

-- End-of-chat feedback (collected when a user ends a conversation).
create table public.chat_feedback (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid references public.conversations(id) on delete set null,
  rater_id        uuid references public.profiles(id) on delete set null,
  experience      text,   -- Great | Okay | Poor
  professionalism text,   -- Very professional | Professional | Unprofessional
  match_accuracy  text,   -- Spot on | Decent | Off
  note            text,
  created_at      timestamptz not null default now()
);
alter table public.chat_feedback enable row level security;
create policy "feedback: insert own" on public.chat_feedback for insert with check (rater_id = auth.uid());
create policy "feedback: own/admin read" on public.chat_feedback for select using (rater_id = auth.uid() or public.is_admin());

-- Support tickets: technical issues, or abuse reports about a person you chatted with.
create table public.support_tickets (
  id           uuid primary key default gen_random_uuid(),
  reporter_id  uuid references public.profiles(id) on delete set null,
  type         text not null,        -- 'technical' | 'abuse'
  about_name   text,                 -- for abuse: the reported person's display name
  about_id     uuid references public.profiles(id) on delete set null,
  details      text,
  status       text not null default 'open',   -- open | resolved | escalated
  created_at   timestamptz not null default now(),
  resolved_at  timestamptz,
  reviewed_by  uuid references public.profiles(id) on delete set null
);
alter table public.support_tickets enable row level security;
create policy "tickets: insert auth" on public.support_tickets for insert with check (auth.uid() is not null);
create policy "tickets: own/admin read" on public.support_tickets for select using (reporter_id = auth.uid() or public.is_admin());
create policy "tickets: admin update" on public.support_tickets for update using (public.is_admin());

-- Grants (anon/authenticated need these in addition to RLS, per migration 0006).
grant select, insert, update on public.chat_feedback   to authenticated;
grant select, insert, update on public.support_tickets to authenticated;

-- ============================================================================
-- 0010 — seekers_who_liked RPC: posting owners see real seekers who liked a
-- posting, returning SAFE fields only (name/headline/photo — never email).
-- ============================================================================
create or replace function public.seekers_who_liked(p_posting uuid)
returns table(seeker_id uuid, full_name text, headline text, photo_url text, mutual boolean)
language sql stable security definer set search_path = public as $$
  select p.id,
         p.full_name,
         sp.headline,
         sp.photo_url,
         exists(
           select 1 from public.recruiter_interest ri
           where ri.posting_id = p_posting and ri.seeker_id = p.id
         ) as mutual
  from public.seeker_interest si
  join public.profiles p on p.id = si.seeker_id
  left join public.seeker_profiles sp on sp.profile_id = si.seeker_id
  where si.posting_id = p_posting
    and public.owns_posting(p_posting)
  order by si.created_at desc;
$$;

grant execute on function public.seekers_who_liked(uuid) to authenticated;

-- ============================================================================
-- GigCute — my_conversations RPC
-- Returns the caller's conversations with the PEER's display name resolved
-- server-side: the seeker's name (from profiles, normally self/admin-only) is
-- exposed to the recruiter they're already conversing with, and vice-versa.
-- security definer + the participant check keep it from leaking anything the
-- caller couldn't already reach. `i_am_recruiter` lets the UI pick the title.
-- ============================================================================
create or replace function public.my_conversations()
returns table(
  id uuid,
  posting_id uuid,
  seeker_id uuid,
  posting_title text,
  company_name text,
  seeker_name text,
  last_message_at timestamptz,
  i_am_recruiter boolean
)
language sql stable security definer set search_path = public as $$
  select c.id, c.posting_id, c.seeker_id,
         p.title          as posting_title,
         co.name          as company_name,
         pr.full_name     as seeker_name,
         c.last_message_at,
         public.owns_posting(c.posting_id) as i_am_recruiter
  from public.conversations c
  join public.postings  p  on p.id  = c.posting_id
  join public.companies co on co.id = p.company_id
  join public.profiles  pr on pr.id = c.seeker_id
  where c.seeker_id = auth.uid()
     or public.owns_posting(c.posting_id)
     or public.is_admin()
  order by c.last_message_at desc;
$$;

grant execute on function public.my_conversations() to authenticated;

-- ============================================================================
-- GigCute — per-account "GigCute intro" super-invite tracking
-- A new account sees the GigCute new-user intro once; this flag (updated by the
-- user via the existing profiles self-update RLS) keeps it from reappearing
-- across sessions/devices.
-- ============================================================================
alter table public.profiles
  add column if not exists intro_seen boolean not null default false;

-- ============================================================================
-- GigCute — store the seeker's uploaded resume
-- The file goes to the public 'media' Storage bucket (under resumes/<uid>/...)
-- and its public URL is kept here so the profile page can offer a download link.
-- ============================================================================
alter table public.seeker_profiles
  add column if not exists resume_url text;

-- ============================================================================
-- GigCute — public_profile RPC
-- Returns a seeker's shareable profile (name + headline + photo + resume +
-- linkedin + work history + favorited prompt answers) by id, as one JSON object,
-- for the public /profile/<id> page. security definer so the (otherwise
-- self/admin-only) display name can be shown; gated on the profile being visible.
-- Includes the resume_url column add so this file is self-contained.
-- ============================================================================
alter table public.seeker_profiles add column if not exists resume_url text;

create or replace function public.public_profile(p_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select case
    when not exists (
      select 1 from public.seeker_profiles sp
      where sp.profile_id = p_id and sp.is_visible
    ) then null
    else jsonb_build_object(
      'id',           p_id,
      'name',         (select full_name from public.profiles where id = p_id),
      'headline',     sp.headline,
      'photo_url',    sp.photo_url,
      'resume_url',   sp.resume_url,
      'linkedin_url', sp.linkedin_url,
      'work', coalesce((
        select jsonb_agg(jsonb_build_object(
          'title', w.title, 'company', w.company,
          'start', w.start_label, 'end', w.end_label, 'description', w.description
        ) order by w.sort_order)
        from public.work_history w where w.seeker_id = p_id), '[]'::jsonb),
      'prompts', coalesce((
        select jsonb_agg(jsonb_build_object('label', a.prompt_label, 'answer', a.answer) order by a.sort_order)
        from public.seeker_prompt_answers a where a.seeker_id = p_id and a.is_favorite), '[]'::jsonb)
    )
  end
  from public.seeker_profiles sp where sp.profile_id = p_id;
$$;

grant execute on function public.public_profile(uuid) to anon, authenticated;

