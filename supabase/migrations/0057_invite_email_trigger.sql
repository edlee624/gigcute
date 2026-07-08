-- ============================================================================
-- GigCute — email notifications for invites
-- A trigger on public.invites calls the `notify-invite` Edge Function (via
-- pg_net) which sends email through Resend:
--   INSERT                       -> email the candidate ("<Company> wants to chat")
--   UPDATE status accepted/decl. -> email the company owner
--
-- SECURITY NOTE: the function posts an `x-notify-secret` header that must match
-- the NOTIFY_SECRET Edge Function secret. The real value is NOT committed — it's
-- set out-of-band (Supabase secrets API) and embedded in the trigger via the
-- Management API, same pattern/footgun as CRON_SECRET: rotating NOTIFY_SECRET
-- requires re-running this function definition with the new value. The literal
-- __NOTIFY_SECRET__ below is a placeholder for the committed copy.
-- ============================================================================
create or replace function public.notify_invite_trg() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare v_event text;
begin
  if TG_OP = 'INSERT' then
    v_event := 'invite_created';
  elsif TG_OP = 'UPDATE' and new.status is distinct from old.status and new.status in ('accepted','declined') then
    v_event := 'invite_' || new.status;
  else
    return new;
  end if;
  perform net.http_post(
    url := 'https://ztvirfxxyvvcrxcjstzi.supabase.co/functions/v1/notify-invite',
    headers := jsonb_build_object('Content-Type','application/json','x-notify-secret','__NOTIFY_SECRET__'),
    body := jsonb_build_object('invite_id', new.id, 'event', v_event),
    timeout_milliseconds := 8000
  );
  return new;
end $fn$;

drop trigger if exists invites_notify on public.invites;
create trigger invites_notify after insert or update on public.invites
  for each row execute function public.notify_invite_trg();
