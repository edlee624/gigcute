-- ============================================================================
-- GigCute — end-chat notice: record WHO ended a chat so the other party is told,
-- block further messages once ended, and standardize the retention on 30 days.
-- ============================================================================
alter table public.conversations add column if not exists ended_by uuid;

-- end_conversation now also stamps who ended it.
create or replace function public.end_conversation(p_conv uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_access_conversation(p_conv) then return; end if;
  update public.conversations
     set ended_at = now(), ended_by = auth.uid()
   where id = p_conv and ended_at is null;
end $$;
grant execute on function public.end_conversation(uuid) to authenticated;

-- Surface ended_by from my_conversations (return shape changes → drop first).
drop function if exists public.my_conversations();
create function public.my_conversations()
returns table(id uuid, posting_id uuid, seeker_id uuid, posting_title text, company_name text,
              seeker_name text, last_message_at timestamptz, i_am_recruiter boolean,
              ended_at timestamptz, ended_by uuid)
language sql stable security definer set search_path = public as $$
  select c.id, c.posting_id, c.seeker_id,
         p.title      as posting_title,
         co.name      as company_name,
         pr.full_name as seeker_name,
         c.last_message_at,
         public.owns_posting(c.posting_id) as i_am_recruiter,
         c.ended_at, c.ended_by
  from public.conversations c
  join public.postings  p  on p.id  = c.posting_id
  join public.companies co on co.id = p.company_id
  join public.profiles  pr on pr.id = c.seeker_id
  where c.seeker_id = auth.uid()
     or public.owns_posting(c.posting_id)
     or public.is_admin()
  order by c.last_message_at desc;
$$;
grant execute on function public.my_conversations() to authenticated;

-- Lightweight per-conversation end state (for the live thread notice + poll).
create or replace function public.conversation_end_state(p_conv uuid)
returns table(ended_at timestamptz, ended_by uuid)
language sql stable security definer set search_path = public as $$
  select c.ended_at, c.ended_by from public.conversations c
  where c.id = p_conv and public.can_access_conversation(p_conv);
$$;
grant execute on function public.conversation_end_state(uuid) to authenticated;

-- No new messages once a chat is ended (belt-and-suspenders alongside the UI).
create or replace function public.block_msg_on_ended()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.conversations c where c.id = NEW.conversation_id and c.ended_at is not null) then
    raise exception 'This chat has ended.' using errcode = 'GC040';
  end if;
  return NEW;
end $$;
drop trigger if exists trg_block_msg_on_ended on public.messages;
create trigger trg_block_msg_on_ended before insert on public.messages
  for each row execute function public.block_msg_on_ended();

-- Standardize ended-chat retention at 30 days (was 31).
select cron.unschedule('purge-ended-chats');
select cron.schedule('purge-ended-chats', '0 3 * * *',
  $job$delete from public.conversations where ended_at is not null and ended_at < now() - interval '30 days'$job$);
