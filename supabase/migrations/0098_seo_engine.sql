-- ============================================================================
-- GigCute — SEO content engine (programmatic hub pages).
--
-- ~196k live jobs across ~10k companies is a large long-tail search asset, but
-- only if it is reachable as indexable pages. This adds the data layer:
--
--   gc_slug(text)      URL-safe slug (immutable, used for company + role slugs)
--   jobs.role_slug     coarse role family, backfilled + kept fresh by trigger
--   indexes            so a page render is an index hit, never a 196k-row scan
--   seo_* RPCs         exactly what one hub page needs, in one round trip
--
-- IMPORTANT: individual ingested jobs are NOT given their own indexable page.
-- They already live on the employer's Greenhouse/Lever/Workday board, so
-- re-publishing them as JobPosting markup would be duplicate content. We index
-- the HUBS (aggregation + salary stats = the part that is genuinely ours) and
-- link out to the employer. Native GigCute postings are the only thing that may
-- ever carry JobPosting structured data.
-- ============================================================================

create or replace function public.gc_slug(p text)
returns text language sql immutable as $$
  select nullif(trim(both '-' from regexp_replace(lower(coalesce(p,'')), '[^a-z0-9]+', '-', 'g')), '');
$$;

-- ---- role taxonomy --------------------------------------------------------
-- Deliberately coarse: a hub page only earns indexing if it has real depth, so
-- a handful of broad families beats hundreds of thin ones. Order matters — the
-- first match wins, so specific families are checked before general ones.
create or replace function public.gc_role_of(p_title text)
returns text language sql immutable as $$
  select case
    when p_title is null then null
    when p_title ilike '%data scientist%' or p_title ilike '%data analyst%'
      or p_title ilike '%data engineer%'  or p_title ilike '%machine learning%'
      or p_title ilike '%analytics%'                                then 'data'
    when p_title ilike '%product manager%' or p_title ilike '%product owner%'
      or p_title ilike '%product lead%'                             then 'product'
    when p_title ilike '%project manager%' or p_title ilike '%program manager%'
      or p_title ilike '%scrum master%'                             then 'project-management'
    when p_title ilike '%engineer%' or p_title ilike '%developer%'
      or p_title ilike '%architect%' or p_title ilike '%programmer%'
      or p_title ilike '%devops%'                                   then 'engineering'
    when p_title ilike '%designer%' or p_title ilike '%ux%' or p_title ilike '%ui %'
      or p_title ilike '%creative%'                                 then 'design'
    when p_title ilike '%nurse%' or p_title ilike '%clinical%' or p_title ilike '%physician%'
      or p_title ilike '%therapist%' or p_title ilike '%medical%'
      or p_title ilike '%healthcare%' or p_title ilike '%pharmac%'  then 'healthcare'
    when p_title ilike '%marketing%' or p_title ilike '%content%' or p_title ilike '%seo%'
      or p_title ilike '%brand%' or p_title ilike '%communications%' then 'marketing'
    when p_title ilike '%sales%' or p_title ilike '%account executive%'
      or p_title ilike '%business development%'                     then 'sales'
    when p_title ilike '%customer success%' or p_title ilike '%customer service%'
      or p_title ilike '%customer support%' or p_title ilike '%help desk%'
      or p_title ilike '%support specialist%'                       then 'customer-support'
    when p_title ilike '%accountant%' or p_title ilike '%accounting%'
      or p_title ilike '%financ%' or p_title ilike '%controller%'
      or p_title ilike '%auditor%'                                  then 'finance'
    when p_title ilike '%human resource%' or p_title ilike '%recruit%'
      or p_title ilike '%people operations%' or p_title ilike '%talent%' then 'hr'
    when p_title ilike '%teacher%' or p_title ilike '%instructor%'
      or p_title ilike '%professor%' or p_title ilike '%tutor%'      then 'education'
    when p_title ilike '%attorney%' or p_title ilike '%lawyer%'
      or p_title ilike '%paralegal%' or p_title ilike '%counsel%'    then 'legal'
    when p_title ilike '%operations%' or p_title ilike '%logistics%'
      or p_title ilike '%supply chain%' or p_title ilike '%warehouse%' then 'operations'
    else 'other' end;
$$;

-- Human-readable labels for the families above.
create table if not exists public.seo_roles (
  slug text primary key,
  label text not null,
  plural text not null,
  sort_order int not null default 100
);
insert into public.seo_roles(slug, label, plural, sort_order) values
  ('engineering','Engineering','Engineering jobs',10),
  ('data','Data','Data jobs',20),
  ('product','Product','Product management jobs',30),
  ('design','Design','Design jobs',40),
  ('sales','Sales','Sales jobs',50),
  ('marketing','Marketing','Marketing jobs',60),
  ('finance','Finance & Accounting','Finance and accounting jobs',70),
  ('customer-support','Customer Support','Customer support jobs',80),
  ('project-management','Project Management','Project management jobs',90),
  ('healthcare','Healthcare','Healthcare jobs',100),
  ('operations','Operations','Operations jobs',110),
  ('hr','HR & Recruiting','HR and recruiting jobs',120),
  ('education','Education','Education jobs',130),
  ('legal','Legal','Legal jobs',140)
on conflict (slug) do update set label=excluded.label, plural=excluded.plural, sort_order=excluded.sort_order;

alter table public.seo_roles enable row level security;
drop policy if exists seo_roles_read on public.seo_roles;
create policy seo_roles_read on public.seo_roles for select using (true);
grant select on public.seo_roles to anon, authenticated;

-- ---- role_slug on jobs (trigger-maintained, so ingest keeps it correct) ----
alter table public.jobs add column if not exists role_slug text;

create or replace function public.jobs_set_role_slug() returns trigger
language plpgsql as $$
begin
  if new.role_slug is null or new.title is distinct from coalesce(old.title, '') then
    new.role_slug := public.gc_role_of(new.title);
  end if;
  return new;
end $$;
drop trigger if exists jobs_role_slug_trg on public.jobs;
create trigger jobs_role_slug_trg before insert or update of title on public.jobs
  for each row execute function public.jobs_set_role_slug();

update public.jobs set role_slug = public.gc_role_of(title) where role_slug is null;

-- ---- indexes: every hub query must be an index hit -------------------------
create index if not exists jobs_company_slug_idx on public.jobs (public.gc_slug(company)) where is_active;
create index if not exists jobs_role_state_idx   on public.jobs (role_slug, us_state) where is_active;
create index if not exists jobs_role_remote_idx  on public.jobs (role_slug, remote) where is_active;
create index if not exists jobs_state_idx        on public.jobs (us_state) where is_active;

-- ---- RPCs: one round trip per rendered page --------------------------------
-- A company hub: "Jobs at <Company>".
create or replace function public.seo_company(p_slug text, p_limit int default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_name text; v_total int; v jsonb;
begin
  select company, count(*) into v_name, v_total
    from public.jobs where is_active and public.gc_slug(company) = p_slug
    group by company order by count(*) desc limit 1;
  if v_name is null then return null; end if;

  select jsonb_build_object(
    'slug', p_slug, 'name', v_name, 'total', v_total,
    -- 54% of ingested company values are lowercase ATS board handles
    -- ("equipmentsharecom"). Those make poor, spammy-looking pages, so the
    -- renderer noindexes them and the sitemap omits them until the name is real.
    'named', (v_name ~ '[A-Z]' or v_name like '% %'),
    'salary', (select jsonb_build_object(
        'min', round(percentile_cont(0.25) within group (order by salary_min)),
        'median', round(percentile_cont(0.5) within group (order by (salary_min+salary_max)/2.0)),
        'max', round(percentile_cont(0.75) within group (order by salary_max)))
      from public.jobs where is_active and public.gc_slug(company)=p_slug
        and salary_min is not null and salary_max is not null),
    'roles', (select coalesce(jsonb_agg(jsonb_build_object('slug', role_slug, 'n', n) order by n desc), '[]'::jsonb)
      from (select role_slug, count(*) n from public.jobs
            where is_active and public.gc_slug(company)=p_slug and role_slug is not null and role_slug <> 'other'
            group by role_slug order by n desc limit 8) r),
    'locations', (select coalesce(jsonb_agg(jsonb_build_object('state', us_state, 'n', n) order by n desc), '[]'::jsonb)
      from (select us_state, count(*) n from public.jobs
            where is_active and public.gc_slug(company)=p_slug and us_state is not null
            group by us_state order by n desc limit 8) l),
    'jobs', (select coalesce(jsonb_agg(jsonb_build_object(
        'title', title, 'location', location, 'remote', remote, 'url', url,
        'posted_at', posted_at, 'salary_min', salary_min, 'salary_max', salary_max)
        order by posted_at desc nulls last), '[]'::jsonb)
      from (select * from public.jobs where is_active and public.gc_slug(company)=p_slug
            order by posted_at desc nulls last limit p_limit) j)
  ) into v;
  return v;
end $$;
grant execute on function public.seo_company(text, int) to anon, authenticated;

-- A role hub, optionally narrowed to a US state or to remote-only.
create or replace function public.seo_role(p_role text, p_state text default null,
  p_remote boolean default false, p_limit int default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_total int; v_label text; v jsonb;
begin
  select label into v_label from public.seo_roles where slug = p_role;
  if v_label is null then return null; end if;

  select count(*) into v_total from public.jobs
   where is_active and role_slug = p_role
     and (p_state is null or us_state = upper(p_state))
     and (not p_remote or remote);

  select jsonb_build_object(
    'role', p_role, 'label', v_label, 'state', upper(p_state), 'remote', p_remote, 'total', v_total,
    'salary', (select jsonb_build_object(
        'min', round(percentile_cont(0.25) within group (order by salary_min)),
        'median', round(percentile_cont(0.5) within group (order by (salary_min+salary_max)/2.0)),
        'max', round(percentile_cont(0.75) within group (order by salary_max)))
      from public.jobs where is_active and role_slug=p_role
        and (p_state is null or us_state=upper(p_state)) and (not p_remote or remote)
        and salary_min is not null and salary_max is not null),
    'companies', (select coalesce(jsonb_agg(jsonb_build_object('name', company, 'slug', public.gc_slug(company), 'n', n) order by n desc), '[]'::jsonb)
      from (select company, count(*) n from public.jobs
            where is_active and role_slug=p_role and company is not null
              and (p_state is null or us_state=upper(p_state)) and (not p_remote or remote)
            group by company order by n desc limit 12) c),
    'states', (select coalesce(jsonb_agg(jsonb_build_object('state', us_state, 'n', n) order by n desc), '[]'::jsonb)
      from (select us_state, count(*) n from public.jobs
            where is_active and role_slug=p_role and us_state is not null
            group by us_state order by n desc limit 12) s),
    'jobs', (select coalesce(jsonb_agg(jsonb_build_object(
        'title', title, 'company', company, 'location', location, 'remote', remote,
        'url', url, 'posted_at', posted_at, 'salary_min', salary_min, 'salary_max', salary_max)
        order by posted_at desc nulls last), '[]'::jsonb)
      from (select * from public.jobs where is_active and role_slug=p_role
              and (p_state is null or us_state=upper(p_state)) and (not p_remote or remote)
            order by posted_at desc nulls last limit p_limit) j)
  ) into v;
  return v;
end $$;
grant execute on function public.seo_role(text, text, boolean, int) to anon, authenticated;

-- Sitemap feeds. Only URLs that clear the depth bar are ever emitted.
create or replace function public.seo_sitemap_companies(p_min int default 5, p_limit int default 5000, p_offset int default 0)
returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object('slug', slug, 'n', n, 'updated', updated)), '[]'::jsonb)
  from (
    select public.gc_slug(company) slug, count(*) n, max(last_seen_at) updated
    from public.jobs
    where is_active and company is not null
      and (company ~ '[A-Z]' or company like '% %')
    group by public.gc_slug(company)
    having count(*) >= p_min and public.gc_slug(company) is not null
    order by count(*) desc
    limit p_limit offset p_offset
  ) x;
$$;
grant execute on function public.seo_sitemap_companies(int, int, int) to anon, authenticated;

create or replace function public.seo_sitemap_hubs(p_min int default 25)
returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(u), '[]'::jsonb) from (
    -- role (national)
    select jsonb_build_object('path', '/jobs/' || role_slug, 'n', count(*)) u
      from public.jobs where is_active and role_slug is not null and role_slug <> 'other'
      group by role_slug having count(*) >= p_min
    union all
    -- role x state
    select jsonb_build_object('path', '/jobs/' || role_slug || '/' || lower(us_state), 'n', count(*))
      from public.jobs where is_active and role_slug is not null and role_slug <> 'other' and us_state is not null
      group by role_slug, us_state having count(*) >= p_min
    union all
    -- remote x role
    select jsonb_build_object('path', '/jobs/remote/' || role_slug, 'n', count(*))
      from public.jobs where is_active and role_slug is not null and role_slug <> 'other' and remote
      group by role_slug having count(*) >= p_min
    union all
    -- state (all roles)
    select jsonb_build_object('path', '/jobs/in/' || lower(us_state), 'n', count(*))
      from public.jobs where is_active and us_state is not null
      group by us_state having count(*) >= p_min
  ) s;
$$;
grant execute on function public.seo_sitemap_hubs(int) to anon, authenticated;

-- A state hub is role-agnostic: every live job in that state, plus the role mix.
create or replace function public.seo_state(p_state text, p_limit int default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_total int; v jsonb; v_st text := upper(p_state);
begin
  select count(*) into v_total from public.jobs where is_active and us_state = v_st;
  if v_total = 0 then return null; end if;
  select jsonb_build_object(
    'state', v_st, 'total', v_total,
    'salary', (select jsonb_build_object(
        'min', round(percentile_cont(0.25) within group (order by salary_min)),
        'median', round(percentile_cont(0.5) within group (order by (salary_min+salary_max)/2.0)),
        'max', round(percentile_cont(0.75) within group (order by salary_max)))
      from public.jobs where is_active and us_state=v_st and salary_min is not null and salary_max is not null),
    'roles', (select coalesce(jsonb_agg(jsonb_build_object('slug', role_slug, 'n', n) order by n desc), '[]'::jsonb)
      from (select role_slug, count(*) n from public.jobs
            where is_active and us_state=v_st and role_slug is not null and role_slug <> 'other'
            group by role_slug order by n desc limit 12) r),
    'companies', (select coalesce(jsonb_agg(jsonb_build_object('name', company, 'slug', public.gc_slug(company), 'n', n) order by n desc), '[]'::jsonb)
      from (select company, count(*) n from public.jobs
            where is_active and us_state=v_st and company is not null
              and (company ~ '[A-Z]' or company like '% %')
            group by company order by n desc limit 12) c),
    'jobs', (select coalesce(jsonb_agg(jsonb_build_object(
        'title', title, 'company', company, 'location', location, 'remote', remote,
        'url', url, 'posted_at', posted_at, 'salary_min', salary_min, 'salary_max', salary_max)
        order by posted_at desc nulls last), '[]'::jsonb)
      from (select * from public.jobs where is_active and us_state=v_st
            order by posted_at desc nulls last limit p_limit) j)
  ) into v;
  return v;
end $$;
grant execute on function public.seo_state(text, int) to anon, authenticated;
