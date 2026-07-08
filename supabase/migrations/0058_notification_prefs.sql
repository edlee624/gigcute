-- ============================================================================
-- GigCute — notification preferences + new-message email notifications
--   notification_prefs   : per-user email toggles (invites, messages), default on
--   message_notify_state : per (conversation, recipient) last-email time (debounce)
--   messages trigger     : calls notify-message (pg_net) on each new message
-- notify-invite / notify-message check notification_prefs before sending.
-- NOTIFY_SECRET is set out-of-band (placeholder __NOTIFY_SECRET__ committed).
-- ============================================================================
create table if not exists public.notification_prefs (
  user_id        uuid primary key references public.profiles(id) on delete cascade,
  email_invites  boolean not null default true,
  email_messages boolean not null default true,
  updated_at     timestamptz not null default now()
);
alter table public.notification_prefs enable row level security;
drop policy if exists "notif_prefs: own" on public.notification_prefs;
create policy "notif_prefs: own" on public.notification_prefs for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Debounce state — service-role only (RLS on, no policy = no client access).
create table if not exists public.message_notify_state (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  recipient_id    uuid not null references public.profiles(id) on delete cascade,
  last_email_at   timestamptz not null default now(),
  primary key (conversation_id, recipient_id)
);
alter table public.message_notify_state enable row level security;

create or replace function public.notify_message_trg() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  perform net.http_post(
    url := 'https://ztvirfxxyvvcrxcjstzi.supabase.co/functions/v1/notify-message',
    headers := jsonb_build_object('Content-Type','application/json','x-notify-secret','__NOTIFY_SECRET__'),
    body := jsonb_build_object('message_id', new.id),
    timeout_milliseconds := 8000
  );
  return new;
end $fn$;

drop trigger if exists messages_notify on public.messages;
create trigger messages_notify after insert on public.messages
  for each row execute function public.notify_message_trg();
