-- ============================================================================
-- One-time board cleanup: drop Adzuna, purge stale jobs, de-dupe.
-- Safe to re-run. Run in the Supabase SQL editor.
-- ============================================================================

-- 1. Remove the Adzuna source entirely (feed no longer ingests it).
delete from public.jobs where source = 'adzuna';

-- 2. Remove jobs older than 30 days (retention window).
delete from public.jobs where posted_at < now() - interval '30 days';

-- 3. De-dupe: keep ONE row per company|title|location (mirrors the board's
--    dedup key). Keeps the newest / highest-salary row of each group.
delete from public.jobs
where id in (
  select id from (
    select id,
      row_number() over (
        partition by
          lower(coalesce(company, '')),
          lower(coalesce(title, '')),
          regexp_replace(lower(coalesce(location, '')), 'remote', '', 'g')
        order by posted_at desc nulls last, salary_max desc nulls last, id
      ) as rn
    from public.jobs
  ) t
  where t.rn > 1
);
