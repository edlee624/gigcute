-- ============================================================================
-- GigCute — precomputed sitemap URLs.
--
-- The sitemap RPCs used to aggregate the whole jobs table on every request.
-- That fit under PostgREST's ~3s anon statement timeout at ~196k active jobs,
-- but not at ~231k, and 0099 made the company query resolve a display name per
-- ROW instead of per company. Result on production:
--   /sitemap-companies-0.xml -> 404 (seo_sitemap_companies always timed out)
--   /sitemap-hubs.xml        -> only "/" and "/jobs" whenever the hubs query
--                               tripped the timeout, then edge-cached that way
-- so Google was being offered a handful of URLs instead of thousands.
--
-- Fix: compute the URL list on a schedule into seo_sitemap_urls, and have the
-- read RPCs select from that small table. Request cost no longer grows with
-- the jobs table. The read RPCs keep their signatures, so api/sitemap.js is
-- unchanged apart from its error handling.
-- ============================================================================

create table if not exists public.seo_sitemap_urls (
  path text primary key,
  kind text not null check (kind in ('hub', 'company')),
  n int not null,
  updated timestamptz,
  refreshed_at timestamptz not null default now()
);
create index if not exists seo_sitemap_urls_kind_n_idx on public.seo_sitemap_urls (kind, n desc, path);

-- Read only through the SECURITY DEFINER functions below.
alter table public.seo_sitemap_urls enable row level security;
revoke all on public.seo_sitemap_urls from anon, authenticated;

-- ---- refresh ---------------------------------------------------------------
-- Stores everything with >= 5 live jobs; callers apply their own higher bar.
-- Builds into a temp table and swaps in one transaction, so readers always see
-- either the previous complete list or the new complete list — never partial.
create or replace function public.seo_refresh_sitemap()
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_hubs int; v_companies int;
begin
  create temp table _seo_urls (path text primary key, kind text, n int, updated timestamptz) on commit drop;

  -- role (national)
  insert into _seo_urls
  select '/jobs/' || role_slug, 'hub', count(*), max(last_seen_at)
  from public.jobs where is_active and role_slug is not null and role_slug <> 'other'
  group by role_slug having count(*) >= 5;

  -- role x state
  insert into _seo_urls
  select '/jobs/' || role_slug || '/' || lower(us_state), 'hub', count(*), max(last_seen_at)
  from public.jobs where is_active and role_slug is not null and role_slug <> 'other' and us_state is not null
  group by role_slug, us_state having count(*) >= 5;

  -- remote x role
  insert into _seo_urls
  select '/jobs/remote/' || role_slug, 'hub', count(*), max(last_seen_at)
  from public.jobs where is_active and role_slug is not null and role_slug <> 'other' and remote
  group by role_slug having count(*) >= 5;

  -- state (all roles)
  insert into _seo_urls
  select '/jobs/in/' || lower(us_state), 'hub', count(*), max(last_seen_at)
  from public.jobs where is_active and us_state is not null
  group by us_state having count(*) >= 5;

  -- companies: aggregate per company FIRST, then resolve each display name once
  -- (0099 resolved per row, which is what pushed this past the timeout). Several
  -- raw values can share a slug; the page shows the largest one's name, so the
  -- sitemap judges indexability by that same name.
  insert into _seo_urls
  select '/companies/' || s.slug, 'company', s.n, s.updated
  from (
    select r.slug, sum(r.n)::int n, max(r.updated) updated,
           (array_agg(r.name order by r.n desc))[1] name
    from (
      select public.gc_slug(g.company) slug, g.n, g.updated,
             coalesce(d.display_name, g.company) name
      from (
        select company, count(*) n, max(last_seen_at) updated
        from public.jobs where is_active and company is not null
        group by company
      ) g
      left join lateral (
        select cn.display_name from public.company_names cn
        where cn.slug = g.company and cn.display_name is not null
        order by cn.fetched_at desc limit 1
      ) d on true
    ) r
    where r.slug is not null
    group by r.slug
  ) s
  where s.n >= 5 and public.gc_name_is_real(s.name);

  select count(*) filter (where kind = 'hub'), count(*) filter (where kind = 'company')
    into v_hubs, v_companies from _seo_urls;

  -- Refuse to replace a good list with an empty one (e.g. mid-ingest or a
  -- failed purge). An old sitemap is far better than a blank one.
  if v_hubs = 0 or v_companies = 0 then
    raise warning 'seo_refresh_sitemap: empty result (hubs=%, companies=%), keeping previous list', v_hubs, v_companies;
    return jsonb_build_object('ok', false, 'hubs', v_hubs, 'companies', v_companies);
  end if;

  delete from public.seo_sitemap_urls;
  insert into public.seo_sitemap_urls (path, kind, n, updated, refreshed_at)
  select path, kind, n, updated, now() from _seo_urls;

  return jsonb_build_object('ok', true, 'hubs', v_hubs, 'companies', v_companies);
end $$;
revoke all on function public.seo_refresh_sitemap() from public, anon, authenticated;

-- ---- read RPCs (same signatures as 0098/0099) ------------------------------
create or replace function public.seo_sitemap_hubs(p_min int default 25)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('path', path, 'n', n) order by n desc, path), '[]'::jsonb)
  from public.seo_sitemap_urls
  where kind = 'hub' and n >= p_min;
$$;
grant execute on function public.seo_sitemap_hubs(int) to anon, authenticated;

-- Ordered by (n desc, path): the path tiebreak keeps chunk boundaries stable,
-- so a company can't fall between /sitemap-companies-0 and -1 on a re-fetch.
create or replace function public.seo_sitemap_companies(p_min int default 5, p_limit int default 5000, p_offset int default 0)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('slug', substr(path, 12), 'n', n, 'updated', updated)
                            order by n desc, path), '[]'::jsonb)
  from (
    select path, n, updated from public.seo_sitemap_urls
    where kind = 'company' and n >= p_min
    order by n desc, path
    limit p_limit offset p_offset
  ) x;
$$;
grant execute on function public.seo_sitemap_companies(int, int, int) to anon, authenticated;

-- ---- schedule: after the 03:00–03:30 purge window, and again mid-afternoon --
do $$ begin
  if exists (select 1 from cron.job where jobname = 'seo-refresh-sitemap') then
    perform cron.unschedule('seo-refresh-sitemap');
  end if;
end $$;
select cron.schedule('seo-refresh-sitemap', '0 4,16 * * *', $$select public.seo_refresh_sitemap()$$);

-- Populate immediately so the sitemap is correct as soon as this applies.
select public.seo_refresh_sitemap();
