-- ============================================================================
-- GigCute — posting lifecycle: 14-day active window, pause, expire, 30-day purge
--   expires_at     — when an active posting expires (null when draft/paused)
--   days_remaining — frozen day budget while paused/draft (default 14)
--   expired_at     — when it expired (kept 30 days, then deleted)
-- Pause freezes the countdown; activating spends the remaining budget.
-- ============================================================================
alter table public.postings add column if not exists expires_at     timestamptz;
alter table public.postings add column if not exists days_remaining int not null default 14;
alter table public.postings add column if not exists expired_at      timestamptz;

-- Give existing active postings a fresh 14-day window (don't surprise-expire them).
update public.postings set expires_at = now() + interval '14 days', days_remaining = 14
  where status = 'active' and expires_at is null;

-- Activate / repost: fresh 14 days if it had expired or ran out, else spend remaining.
create or replace function public.posting_activate(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_days int;
begin
  if not public.owns_posting(p_id) then return; end if;
  select case when status = 'expired' or days_remaining <= 0 then 14 else days_remaining end
    into v_days from public.postings where id = p_id;
  update public.postings
     set status = 'active', days_remaining = v_days,
         expires_at = now() + (v_days || ' days')::interval,
         expired_at = null, published_at = now()
   where id = p_id;
end $$;
grant execute on function public.posting_activate(uuid) to authenticated;

-- Pause (save as draft): freeze the remaining-day budget, stop the countdown.
create or replace function public.posting_pause(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.owns_posting(p_id) then return; end if;
  update public.postings
     set days_remaining = greatest(0, ceil(extract(epoch from (expires_at - now())) / 86400)::int),
         status = 'draft', expires_at = null
   where id = p_id and status = 'active';
end $$;
grant execute on function public.posting_pause(uuid) to authenticated;

-- Owner deletes a posting outright (used for expired ones).
create or replace function public.posting_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.owns_posting(p_id) then return; end if;
  delete from public.postings where id = p_id;
end $$;
grant execute on function public.posting_delete(uuid) to authenticated;

-- Daily: expire active postings past their window; purge expired ones after 30 days.
select cron.schedule('expire-postings', '5 3 * * *',
  $job$update public.postings set status='expired', expired_at=now(), days_remaining=0
        where status='active' and expires_at is not null and expires_at < now()$job$);
select cron.schedule('purge-expired-postings', '10 3 * * *',
  $job$delete from public.postings where status='expired' and expired_at is not null
        and expired_at < now() - interval '30 days'$job$);
