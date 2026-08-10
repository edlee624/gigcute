-- ============================================================================
-- GigCute — real company display names for the SEO company hubs.
--
-- jobs.company holds whatever the ATS board is keyed by, which for most sources
-- is a handle rather than a name: "equipmentsharecom", "urpt", "plscareers".
-- Those made poor hub pages, so 0098 noindexed them — 3,664 of 5,044 company
-- pages were withheld.
--
-- Greenhouse exposes the real name at /v1/boards/{slug} ("EquipmentShare",
-- "Upstream Rehabilitation", "PLS"). This table caches that lookup so the hubs
-- can show a real name and earn indexing. Populated by a backfill pass; ingest
-- can fold the same lookup in later (deliberately NOT wired into ingest-jobs
-- here, to avoid colliding with in-flight work on that function).
--
-- The URL key is unchanged: /companies/<gc_slug(jobs.company)> still resolves,
-- so nothing already crawled or sitemapped moves. Only the displayed name,
-- title, and indexability change.
-- ============================================================================

create table if not exists public.company_names (
  source text not null,
  slug text not null,
  display_name text,
  fetched_at timestamptz not null default now(),
  primary key (source, slug)
);
create index if not exists company_names_slug_idx on public.company_names (slug) where display_name is not null;

-- Read only through the SECURITY DEFINER seo_* functions; no direct client access.
alter table public.company_names enable row level security;
revoke all on public.company_names from anon, authenticated;

-- Resolved display name, falling back to the raw value when we have no better one.
create or replace function public.gc_company_display(p_company text)
returns text language sql stable security definer set search_path=public as $$
  select coalesce(
    (select cn.display_name from public.company_names cn
      where cn.slug = p_company and cn.display_name is not null
      order by cn.fetched_at desc limit 1),
    p_company);
$$;

-- A name is "real" (worth indexing) if it has capitals or spaces — the same bar
-- 0098 used, now applied to the resolved name rather than the raw handle.
create or replace function public.gc_name_is_real(p_name text)
returns boolean language sql immutable as $$
  select p_name is not null and (p_name ~ '[A-Z]' or p_name like '% %');
$$;

-- ---- company hub: show the resolved name, and index on that basis ----------
create or replace function public.seo_company(p_slug text, p_limit int default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_raw text; v_name text; v_total int; v jsonb;
begin
  select company, count(*) into v_raw, v_total
    from public.jobs where is_active and public.gc_slug(company) = p_slug
    group by company order by count(*) desc limit 1;
  if v_raw is null then return null; end if;
  v_name := public.gc_company_display(v_raw);

  select jsonb_build_object(
    'slug', p_slug, 'name', v_name, 'total', v_total,
    'named', public.gc_name_is_real(v_name),
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

-- ---- sitemap: list a company once its resolved name is real ----------------
create or replace function public.seo_sitemap_companies(p_min int default 5, p_limit int default 5000, p_offset int default 0)
returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object('slug', slug, 'n', n, 'updated', updated)), '[]'::jsonb)
  from (
    select public.gc_slug(company) slug, count(*) n, max(last_seen_at) updated
    from public.jobs
    where is_active and company is not null
      and public.gc_name_is_real(public.gc_company_display(company))
    group by public.gc_slug(company)
    having count(*) >= p_min and public.gc_slug(company) is not null
    order by count(*) desc
    limit p_limit offset p_offset
  ) x;
$$;
grant execute on function public.seo_sitemap_companies(int, int, int) to anon, authenticated;
