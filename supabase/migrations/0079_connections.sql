-- ============================================================================
-- GigCute — seeker ↔ seeker connections (professional network graph).
-- Symmetric once accepted. Participants must have a seeker profile (so a
-- recruiter who also builds a seeker profile can take part). Graph only in v1 —
-- no direct messaging yet. Requests/acceptances land in the in-app inbox
-- (user_notifications) via a trigger.
-- ============================================================================

-- eligibility: does this user have a seeker profile?
create or replace function public.is_seeker(uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.seeker_profiles where profile_id = uid);
$$;
grant execute on function public.is_seeker(uuid) to authenticated;

create table if not exists public.connections (
  id           uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete cascade,
  addressee_id uuid not null references public.profiles(id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending','accepted')),
  created_at   timestamptz not null default now(),
  responded_at timestamptz,
  check (requester_id <> addressee_id)
);
-- one edge per unordered pair (blocks duplicate + reverse-duplicate requests)
create unique index if not exists connections_pair_uidx
  on public.connections (least(requester_id, addressee_id), greatest(requester_id, addressee_id));
create index if not exists connections_addressee_idx on public.connections (addressee_id, status);
create index if not exists connections_requester_idx on public.connections (requester_id, status);

alter table public.connections enable row level security;
-- see only edges you're part of
drop policy if exists "conn: mine" on public.connections;
create policy "conn: mine" on public.connections for select
  using (requester_id = auth.uid() or addressee_id = auth.uid());
-- send a request: you're the requester, both sides are seekers, starts pending
drop policy if exists "conn: request" on public.connections;
create policy "conn: request" on public.connections for insert
  with check (requester_id = auth.uid() and status = 'pending'
              and public.is_seeker(auth.uid()) and public.is_seeker(addressee_id));
-- accept: the addressee flips it to accepted
drop policy if exists "conn: accept" on public.connections;
create policy "conn: accept" on public.connections for update
  using (addressee_id = auth.uid()) with check (addressee_id = auth.uid() and status = 'accepted');
-- ignore / cancel / remove: either party can delete the edge
drop policy if exists "conn: delete" on public.connections;
create policy "conn: delete" on public.connections for delete
  using (requester_id = auth.uid() or addressee_id = auth.uid());
grant select, insert, update, delete on public.connections to authenticated;

-- ---- in-app notifications on request / accept -----------------------------
create or replace function public.connections_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare nm text; cd text;
begin
  if TG_OP = 'INSERT' then
    select full_name into nm from public.profiles where id = new.requester_id;
    select public_code into cd from public.seeker_profiles where profile_id = new.requester_id;
    insert into public.user_notifications (user_id, kind, title, body, link)
    values (new.addressee_id, 'connection_request', 'New connection request',
            coalesce(nullif(btrim(nm), ''), 'Someone') || ' wants to connect on GigCute.',
            case when cd is not null then '/profile/' || cd else null end);
  elsif TG_OP = 'UPDATE' and new.status = 'accepted' and coalesce(old.status, '') <> 'accepted' then
    select full_name into nm from public.profiles where id = new.addressee_id;
    select public_code into cd from public.seeker_profiles where profile_id = new.addressee_id;
    insert into public.user_notifications (user_id, kind, title, body, link)
    values (new.requester_id, 'connection_accepted', 'Connection accepted',
            coalesce(nullif(btrim(nm), ''), 'Your request') || ' accepted your connection.',
            case when cd is not null then '/profile/' || cd else null end);
  end if;
  return new;
end $$;
drop trigger if exists connections_notify_trg on public.connections;
create trigger connections_notify_trg after insert or update on public.connections
  for each row execute function public.connections_notify();

-- ---- read RPCs (each scoped to the caller) --------------------------------
create or replace function public.connection_status(p_other uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); c public.connections;
begin
  if me is null or not public.is_seeker(me) then return null; end if;  -- viewer ineligible
  if p_other = me then return null; end if;
  select * into c from public.connections
   where (requester_id = me and addressee_id = p_other)
      or (requester_id = p_other and addressee_id = me)
   limit 1;
  if not found then return jsonb_build_object('state', 'none', 'id', null); end if;
  if c.status = 'accepted' then return jsonb_build_object('state', 'connected', 'id', c.id); end if;
  if c.requester_id = me then return jsonb_build_object('state', 'outgoing', 'id', c.id); end if;
  return jsonb_build_object('state', 'incoming', 'id', c.id);
end $$;
grant execute on function public.connection_status(uuid) to authenticated;

create or replace function public.my_connections()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'connection_id', c.id, 'user_id', other.id, 'name', p.full_name,
      'headline', sp.headline, 'photo_url', sp.photo_url, 'code', sp.public_code,
      'since', c.responded_at
    ) order by c.responded_at desc nulls last), '[]'::jsonb)
  from public.connections c
  join lateral (select case when c.requester_id = auth.uid() then c.addressee_id else c.requester_id end as id) other on true
  join public.profiles p on p.id = other.id
  left join public.seeker_profiles sp on sp.profile_id = other.id
  where c.status = 'accepted' and (c.requester_id = auth.uid() or c.addressee_id = auth.uid());
$$;
grant execute on function public.my_connections() to authenticated;

create or replace function public.connection_requests()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'connection_id', c.id, 'user_id', c.requester_id, 'name', p.full_name,
      'headline', sp.headline, 'photo_url', sp.photo_url, 'code', sp.public_code,
      'requested_at', c.created_at
    ) order by c.created_at desc), '[]'::jsonb)
  from public.connections c
  join public.profiles p on p.id = c.requester_id
  left join public.seeker_profiles sp on sp.profile_id = c.requester_id
  where c.status = 'pending' and c.addressee_id = auth.uid();
$$;
grant execute on function public.connection_requests() to authenticated;
