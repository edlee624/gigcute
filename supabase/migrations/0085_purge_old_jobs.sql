-- Bounded retention purge. The edge function previously did a single
-- DELETE ... WHERE posted_at < cutoff, which times out once the over-retention
-- backlog is large (a 120k-row delete exceeds the worker statement timeout) — so
-- the purge silently failed and old jobs accumulated. This deletes at most p_limit
-- rows per call; the cron loops it a few times per run and catches up over runs.
create or replace function public.purge_old_jobs(p_days int, p_limit int)
returns integer language plpgsql as $$
declare n integer;
begin
  delete from public.jobs
  where ctid in (
    select ctid from public.jobs
    where posted_at < now() - (p_days || ' days')::interval
    limit p_limit
  );
  get diagnostics n = row_count;
  return n;
end $$;
