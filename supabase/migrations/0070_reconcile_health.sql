-- ============================================================================
-- GigCute — ingest reconciliation + daily health report (service-role only).
--
-- touch_and_reconcile: called by ingest-jobs per company AFTER fetching that
-- company's FULL board. Jobs still on the board get last_seen_at refreshed
-- (and reactivated if needed); jobs of that company that are no longer on the
-- board closed at the source → deactivated (then purged by the 3-day cron).
-- Array param via RPC body avoids URL-length limits on big boards.
--
-- health_report: one JSON blob for the daily health-check edge function —
-- cron failures, ingest freshness, job counts, DB size, recent 5xx.
-- Both are service-role only (no anon/authenticated execute).
-- ============================================================================
create or replace function public.touch_and_reconcile(p_source text, p_prefix text, p_seen text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.jobs set last_seen_at = now(), is_active = true
   where source = p_source and external_id = any(p_seen);
  update public.jobs set is_active = false
   where source = p_source and external_id like p_prefix
     and is_active and not (external_id = any(p_seen));
end $$;
revoke execute on function public.touch_and_reconcile(text, text, text[]) from public, anon, authenticated;

create or replace function public.health_report()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'db_size',        pg_size_pretty(pg_database_size(current_database())),
    'jobs_total',     (select count(*) from public.jobs),
    'jobs_active',    (select count(*) from public.jobs where is_active),
    'jobs_24h',       (select count(*) from public.jobs where created_at > now() - interval '24 hours'),
    'users_total',    (select count(*) from auth.users),
    'users_24h',      (select count(*) from auth.users where created_at > now() - interval '24 hours'),
    'http_5xx_24h',   (select count(*) from net._http_response where status_code >= 500 and created > now() - interval '24 hours'),
    'cron_failures_24h', (
      select coalesce(jsonb_agg(jsonb_build_object('job', j.jobname, 'status', d.status, 'at', d.start_time, 'msg', left(d.return_message, 200))), '[]'::jsonb)
      from cron.job_run_details d join cron.job j on j.jobid = d.jobid
      where d.status <> 'succeeded' and d.start_time > now() - interval '24 hours')
  );
$$;
revoke execute on function public.health_report() from public, anon, authenticated;
