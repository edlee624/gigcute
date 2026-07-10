-- ============================================================================
-- GigCute — block users. A block prevents messaging in EITHER direction and
-- archives any open conversation between the two. (Reporting reuses the existing
-- public.reports table via the reports.file API.)
-- ============================================================================
create table if not exists public.blocks (
  blocker_id uuid not null references auth.users(id) on delete cascade,
  blocked_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);
alter table public.blocks enable row level security;
drop policy if exists "blocks: owner all" on public.blocks;
create policy "blocks: owner all" on public.blocks for all
  using (blocker_id = auth.uid()) with check (blocker_id = auth.uid());

-- The user ids the caller has blocked.
create or replace function public.my_blocks()
returns setof uuid language sql stable security definer set search_path = public as $$
  select blocked_id from public.blocks where blocker_id = auth.uid();
$$;
grant execute on function public.my_blocks() to authenticated;

-- Block the OTHER participant of a conversation, and archive that conversation.
create or replace function public.block_conversation_peer(p_conv uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_seeker uuid; v_owner uuid; v_other uuid;
begin
  select c.seeker_id, co.owner_id into v_seeker, v_owner
    from public.conversations c
    join public.postings  p  on p.id = c.posting_id
    join public.companies co on co.id = p.company_id
   where c.id = p_conv;
  if v_seeker is null then return; end if;
  if auth.uid() not in (v_seeker, v_owner) and not public.is_admin() then return; end if;
  v_other := case when auth.uid() = v_seeker then v_owner else v_seeker end;
  if v_other is null or v_other = auth.uid() then return; end if;
  insert into public.blocks (blocker_id, blocked_id) values (auth.uid(), v_other)
    on conflict (blocker_id, blocked_id) do nothing;
  update public.conversations
     set ended_at = coalesce(ended_at, now()), ended_by = coalesce(ended_by, auth.uid())
   where id = p_conv;
end $$;
grant execute on function public.block_conversation_peer(uuid) to authenticated;

-- Unblock a user directly (for a future "blocked users" settings screen).
create or replace function public.unblock_user(p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.blocks where blocker_id = auth.uid() and blocked_id = p_target;
end $$;
grant execute on function public.unblock_user(uuid) to authenticated;

-- Enforce: no messages between users where a block exists either way.
create or replace function public.block_msg_if_blocked()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_seeker uuid; v_owner uuid; v_other uuid;
begin
  select c.seeker_id, co.owner_id into v_seeker, v_owner
    from public.conversations c
    join public.postings  p  on p.id = c.posting_id
    join public.companies co on co.id = p.company_id
   where c.id = NEW.conversation_id;
  v_other := case when NEW.sender_id = v_seeker then v_owner else v_seeker end;
  if v_other is not null and exists (
    select 1 from public.blocks
     where (blocker_id = NEW.sender_id and blocked_id = v_other)
        or (blocker_id = v_other and blocked_id = NEW.sender_id)) then
    raise exception 'You can no longer message this user.' using errcode = 'GC050';
  end if;
  return NEW;
end $$;
drop trigger if exists trg_block_msg_if_blocked on public.messages;
create trigger trg_block_msg_if_blocked before insert on public.messages
  for each row execute function public.block_msg_if_blocked();
