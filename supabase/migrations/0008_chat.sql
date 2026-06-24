-- ============================================================================
-- GigCute — chat / messaging
-- A conversation exists per (posting, seeker) and only opens once the connection
-- is mutual: either a match (both expressed interest) or an accepted invite —
-- "the conversation begins when both say yes". Participants are the seeker and
-- the posting's company members. Realtime delivers new messages live.
-- ============================================================================

-- Is there an open connection between this posting and seeker?
create or replace function public.connection_open(p_posting uuid, p_seeker uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.matches m where m.posting_id = p_posting and m.seeker_id = p_seeker)
      or exists (select 1 from public.invites i where i.posting_id = p_posting and i.seeker_id = p_seeker and i.status = 'accepted');
$$;

create table public.conversations (
  id              uuid primary key default gen_random_uuid(),
  posting_id      uuid not null references public.postings(id) on delete cascade,
  seeker_id       uuid not null references public.seeker_profiles(profile_id) on delete cascade,
  created_at      timestamptz not null default now(),
  last_message_at timestamptz not null default now(),
  unique (posting_id, seeker_id)
);
alter table public.conversations enable row level security;
create index on public.conversations (seeker_id);
create index on public.conversations (posting_id);

create policy "conv: participants read" on public.conversations for select
  using (seeker_id = auth.uid() or public.owns_posting(posting_id) or public.is_admin());
create policy "conv: open connection insert" on public.conversations for insert
  with check ((seeker_id = auth.uid() or public.owns_posting(posting_id)) and public.connection_open(posting_id, seeker_id));
create policy "conv: participants update" on public.conversations for update
  using (seeker_id = auth.uid() or public.owns_posting(posting_id));

-- Can the current user access this conversation? (used by message policies)
create or replace function public.can_access_conversation(p_conv uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.conversations c
    where c.id = p_conv
      and (c.seeker_id = auth.uid() or public.owns_posting(c.posting_id) or public.is_admin())
  );
$$;

create table public.messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id       uuid references public.profiles(id) on delete set null,
  body            text not null,
  created_at      timestamptz not null default now(),
  read_at         timestamptz
);
alter table public.messages enable row level security;
create index on public.messages (conversation_id, created_at);

create policy "msg: participants read" on public.messages for select
  using (public.can_access_conversation(conversation_id));
create policy "msg: sender insert" on public.messages for insert
  with check (sender_id = auth.uid() and public.can_access_conversation(conversation_id));
create policy "msg: recipient mark read" on public.messages for update
  using (public.can_access_conversation(conversation_id));

-- Bump the conversation's last_message_at on every new message (for sort/preview).
create or replace function public.touch_conversation()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.conversations set last_message_at = now() where id = new.conversation_id;
  return new;
end; $$;
create trigger messages_touch_conv after insert on public.messages
  for each row execute function public.touch_conversation();

-- Realtime: stream inserts to subscribed participants (filtered by RLS).
alter publication supabase_realtime add table public.messages;
alter publication supabase_realtime add table public.conversations;
