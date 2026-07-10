-- ============================================================================
-- GigCute — clear "Removed" tracker entries once the underlying ad is closed.
-- A dismissed tracked_job is pruned when its job is no longer active (is_active
-- = false) or the job row is gone (job_id nulled by ON DELETE SET NULL). Saved
-- and Applied entries are left alone — those are the user's intentional records.
-- ============================================================================
create or replace function public.tracker_prune_dismissed()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with del as (
    delete from public.tracked_jobs t
     where t.user_id = auth.uid()
       and t.status = 'dismissed'
       and (t.job_id is null
            or not exists (select 1 from public.jobs j where j.id = t.job_id and j.is_active))
    returning 1)
  select count(*) into n from del;
  return n;
end $$;
grant execute on function public.tracker_prune_dismissed() to authenticated;

-- Nightly global cleanup so the Removed list clears even if the tracker isn't opened.
select cron.schedule('prune-dismissed-closed', '20 3 * * *',
  $job$delete from public.tracked_jobs t where t.status='dismissed'
        and (t.job_id is null or not exists (select 1 from public.jobs j where j.id=t.job_id and j.is_active))$job$);
