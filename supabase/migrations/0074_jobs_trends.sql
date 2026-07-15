-- ============================================================================
-- GigCute — jobs salary TRENDS OVER TIME (admin analytics).
--   jobs_trends(p_months)   : monthly time-series of salary medians + counts,
--                             overall and broken down by seniority / remote /
--                             category (top) / location (top). Buckets on
--                             posted_at, so it reflects real historical spread.
--   jobs_daily_snapshot     : durable daily aggregate of the LIVE feed, so trend
--                             history survives even as stale jobs are purged.
--   snapshot_jobs_daily()   : upserts today's snapshot; run daily by pg_cron.
-- Salary = midpoint of (min,max) when both present, else whichever exists.
-- All admin-gated. Seniority derived by the same regex used in jobs_analytics.
-- ============================================================================

-- ---- durable daily snapshot of the live feed ------------------------------
create table if not exists public.jobs_daily_snapshot (
  day           date primary key,
  total_active  int,
  with_salary   int,
  median        int,
  p25           int,
  p75           int,
  by_seniority  jsonb,
  by_remote     jsonb,
  created_at    timestamptz not null default now()
);
alter table public.jobs_daily_snapshot enable row level security;
drop policy if exists "jobs snapshot admin read" on public.jobs_daily_snapshot;
create policy "jobs snapshot admin read" on public.jobs_daily_snapshot
  for select using (public.is_admin());
grant select on public.jobs_daily_snapshot to authenticated;

create or replace function public.snapshot_jobs_daily()
returns void language plpgsql security definer set search_path = public as $$
begin
  with j as (
    select
      case
        when title ~* '\m(chief|cxo|founder|c-level)\M' then 'C-level / Founder'
        when title ~* '\m(vp|vice president|svp|evp|head of)\M' then 'VP / Head'
        when title ~* '\m(director)\M' then 'Director'
        when title ~* '\m(manager|mgr)\M' then 'Manager'
        when title ~* '\m(principal|staff|lead)\M' then 'Staff / Principal / Lead'
        when title ~* '\m(senior|sr)\M' then 'Senior'
        when title ~* '\m(junior|jr|entry|associate|intern|graduate|trainee)\M' then 'Entry / Junior'
        else 'Mid / Unspecified'
      end as seniority,
      case when remote then 'Remote' else 'On-site / Hybrid' end as remote_kind,
      case
        when salary_min is not null and salary_max is not null then (salary_min + salary_max) / 2.0
        when salary_max is not null then salary_max::numeric
        when salary_min is not null then salary_min::numeric
      end as mid
    from public.jobs where is_active
  )
  insert into public.jobs_daily_snapshot as s
    (day, total_active, with_salary, median, p25, p75, by_seniority, by_remote)
  select current_date,
    (select count(*) from j),
    (select count(*) from j where mid is not null),
    (select round(percentile_cont(0.5) within group (order by mid))::int from j where mid is not null),
    (select round(percentile_cont(0.25) within group (order by mid))::int from j where mid is not null),
    (select round(percentile_cont(0.75) within group (order by mid))::int from j where mid is not null),
    (select coalesce(jsonb_object_agg(seniority, med), '{}') from (
       select seniority, round(percentile_cont(0.5) within group (order by mid))::int med
       from j where mid is not null group by seniority) x),
    (select coalesce(jsonb_object_agg(remote_kind, med), '{}') from (
       select remote_kind, round(percentile_cont(0.5) within group (order by mid))::int med
       from j where mid is not null group by remote_kind) y)
  on conflict (day) do update set
    total_active = excluded.total_active, with_salary = excluded.with_salary,
    median = excluded.median, p25 = excluded.p25, p75 = excluded.p75,
    by_seniority = excluded.by_seniority, by_remote = excluded.by_remote,
    created_at = now();
end $$;
revoke all on function public.snapshot_jobs_daily() from public, anon, authenticated;

-- ---- monthly time-series over posted_at -----------------------------------
create or replace function public.jobs_trends(p_months int default 12)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare result jsonb; m int := greatest(1, least(coalesce(p_months, 12), 36));
begin
  if not public.is_admin() then return null; end if;

  with base as (
    select
      to_char(date_trunc('month', posted_at), 'YYYY-MM') as ym,
      case
        when title ~* '\m(chief|cxo|founder|c-level)\M' then 'C-level / Founder'
        when title ~* '\m(vp|vice president|svp|evp|head of)\M' then 'VP / Head'
        when title ~* '\m(director)\M' then 'Director'
        when title ~* '\m(manager|mgr)\M' then 'Manager'
        when title ~* '\m(principal|staff|lead)\M' then 'Staff / Principal / Lead'
        when title ~* '\m(senior|sr)\M' then 'Senior'
        when title ~* '\m(junior|jr|entry|associate|intern|graduate|trainee)\M' then 'Entry / Junior'
        else 'Mid / Unspecified'
      end as seniority,
      coalesce(nullif(btrim(category), ''), '—') as category,
      coalesce(nullif(btrim(location), ''), '—') as location,
      case when remote then 'Remote' else 'On-site / Hybrid' end as remote_kind,
      case
        when salary_min is not null and salary_max is not null then (salary_min + salary_max) / 2.0
        when salary_max is not null then salary_max::numeric
        when salary_min is not null then salary_min::numeric
      end as mid
    from public.jobs
    where posted_at is not null
      and posted_at >= date_trunc('month', now()) - make_interval(months => m - 1)
  ),
  months as (
    select to_char(date_trunc('month', now()) - make_interval(months => g), 'YYYY-MM') as ym
    from generate_series(0, m - 1) g
  ),
  -- top buckets by volume, so the series stay readable
  top_cat as (
    select category from base where mid is not null and category <> '—'
    group by category order by count(*) desc limit 8
  ),
  top_loc as (
    select location from base where mid is not null and location <> '—'
    group by location order by count(*) desc limit 8
  ),
  agg(dim, bucket, ym, n, med) as (
    select 'overall', 'All', ym, count(*)::int,
           round(percentile_cont(0.5) within group (order by mid))::int
      from base where mid is not null group by ym
    union all
    select 'seniority', seniority, ym, count(*)::int,
           round(percentile_cont(0.5) within group (order by mid))::int
      from base where mid is not null group by seniority, ym
    union all
    select 'remote', remote_kind, ym, count(*)::int,
           round(percentile_cont(0.5) within group (order by mid))::int
      from base where mid is not null group by remote_kind, ym
    union all
    select 'category', category, ym, count(*)::int,
           round(percentile_cont(0.5) within group (order by mid))::int
      from base where mid is not null and category in (select category from top_cat)
      group by category, ym
    union all
    select 'location', location, ym, count(*)::int,
           round(percentile_cont(0.5) within group (order by mid))::int
      from base where mid is not null and location in (select location from top_loc)
      group by location, ym
  )
  select jsonb_build_object(
    'months', (select coalesce(jsonb_agg(ym order by ym), '[]') from months),
    'total_with_salary', (select count(*) from base where mid is not null),
    -- durable daily series of the live feed (grows one row/day; survives purges)
    'daily', (select coalesce(jsonb_agg(jsonb_build_object(
        'day', day, 'total_active', total_active, 'with_salary', with_salary,
        'median', median, 'p25', p25, 'p75', p75,
        'by_seniority', by_seniority, 'by_remote', by_remote) order by day), '[]')
      from public.jobs_daily_snapshot where day >= current_date - 90),
    'series', (
      select coalesce(jsonb_agg(row), '[]') from (
        select jsonb_build_object(
          'dim', dim, 'bucket', bucket,
          'points', jsonb_agg(jsonb_build_object('ym', ym, 'n', n, 'median', med) order by ym)
        ) as row
        from agg group by dim, bucket
        order by dim, max(n) desc
      ) s
    )
  ) into result;

  return result;
end $$;
grant execute on function public.jobs_trends(int) to authenticated;

-- ---- schedule the daily snapshot + seed today now -------------------------
select cron.schedule('jobs-daily-snapshot', '0 6 * * *', $cron$select public.snapshot_jobs_daily()$cron$);
select public.snapshot_jobs_daily();
