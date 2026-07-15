-- ============================================================================
-- GigCute — admin broadcasts + in-app notification inbox.
--   broadcasts          : audit row per admin blast (title/body/filters/reach)
--   user_notifications  : per-user in-app inbox (fanned out on send; own-row RLS)
-- RPCs (all admin-gated):
--   admin_broadcast_recipients(roles, onboarded, active_days) -> set of user ids
--   admin_broadcast_preview(...)  -> reach count (no send)
--   admin_broadcast(title, body, ...) -> inserts audit row + fans out inbox rows
-- Delivery is IN-APP ONLY (no email). Recipients = confirmed users matching the
-- filters at send time; later signups do not receive past blasts (point-in-time).
-- ============================================================================

-- ---- audit table ----------------------------------------------------------
create table if not exists public.broadcasts (
  id              uuid primary key default gen_random_uuid(),
  title           text,
  body            text not null,
  filters         jsonb not null default '{}',
  recipient_count int not null default 0,
  created_by      uuid references public.profiles(id),
  created_at      timestamptz not null default now()
);
alter table public.broadcasts enable row level security;
drop policy if exists "broadcasts admin read" on public.broadcasts;
create policy "broadcasts admin read" on public.broadcasts
  for select using (public.is_admin());
grant select on public.broadcasts to authenticated;

-- ---- per-user inbox -------------------------------------------------------
create table if not exists public.user_notifications (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  kind         text not null default 'broadcast',
  title        text,
  body         text not null,
  link         text,
  broadcast_id uuid references public.broadcasts(id) on delete cascade,
  created_at   timestamptz not null default now(),
  read_at      timestamptz
);
create index if not exists user_notif_user_idx
  on public.user_notifications (user_id, created_at desc);
alter table public.user_notifications enable row level security;
-- Own-row only. No client INSERT/DELETE — fan-out happens in the definer RPC.
drop policy if exists "notif: own read" on public.user_notifications;
create policy "notif: own read" on public.user_notifications
  for select using (user_id = auth.uid());
drop policy if exists "notif: own update" on public.user_notifications;
create policy "notif: own update" on public.user_notifications
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, update on public.user_notifications to authenticated;

-- ---- recipient resolver (internal; called only by the definer RPCs) -------
create or replace function public.admin_broadcast_recipients(
  p_roles text[] default null, p_onboarded boolean default false, p_active_days int default 0)
returns setof uuid language sql stable security definer set search_path = public, auth as $$
  select u.id
  from auth.users u
  join public.profiles p            on p.id = u.id
  left join public.seeker_profiles sp on sp.profile_id = u.id
  where u.email_confirmed_at is not null
    and (p_roles is null or array_length(p_roles, 1) is null or p.role::text = any(p_roles))
    and (not coalesce(p_onboarded, false) or sp.profile_id is not null)
    and (coalesce(p_active_days, 0) <= 0
         or u.last_sign_in_at >= now() - make_interval(days => p_active_days));
$$;
revoke all on function public.admin_broadcast_recipients(text[], boolean, int)
  from public, anon, authenticated;

-- ---- preview reach (no send) ----------------------------------------------
create or replace function public.admin_broadcast_preview(
  p_roles text[] default null, p_onboarded boolean default false, p_active_days int default 0)
returns int language plpgsql stable security definer set search_path = public, auth as $$
declare n int;
begin
  if not public.is_admin() then return null; end if;
  select count(*) into n
  from public.admin_broadcast_recipients(p_roles, p_onboarded, p_active_days);
  return n;
end $$;
grant execute on function public.admin_broadcast_preview(text[], boolean, int) to authenticated;

-- ---- send -----------------------------------------------------------------
create or replace function public.admin_broadcast(
  p_title text, p_body text,
  p_roles text[] default null, p_onboarded boolean default false, p_active_days int default 0)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare bid uuid; n int; me uuid := auth.uid();
begin
  if not public.is_admin() then return null; end if;
  if coalesce(btrim(p_body), '') = '' then raise exception 'message body required'; end if;

  insert into public.broadcasts (title, body, filters, created_by)
  values (nullif(btrim(p_title), ''), btrim(p_body),
          jsonb_build_object('roles', p_roles, 'onboarded', p_onboarded, 'active_days', p_active_days),
          me)
  returning id into bid;

  insert into public.user_notifications (user_id, kind, title, body, broadcast_id)
  select r, 'broadcast', nullif(btrim(p_title), ''), btrim(p_body), bid
  from public.admin_broadcast_recipients(p_roles, p_onboarded, p_active_days) r;
  get diagnostics n = row_count;

  update public.broadcasts set recipient_count = n where id = bid;
  return jsonb_build_object('broadcast_id', bid, 'recipient_count', n);
end $$;
grant execute on function public.admin_broadcast(text, text, text[], boolean, int) to authenticated;
