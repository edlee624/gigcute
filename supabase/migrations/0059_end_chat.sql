-- ============================================================================
-- GigCute — "End chat": archive a conversation + auto-delete after 31 days.
-- Either participant can end a chat (sets ended_at). A daily pg_cron job deletes
-- conversations ended > 31 days ago; messages cascade. Keeps storage bounded so
-- the service stays low-cost.
-- ============================================================================
alter table public.conversations add column if not exists ended_at timestamptz;

-- Either participant can end (archive) the chat.
create or replace function public.end_conversation(p_conv uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_access_conversation(p_conv) then return; end if;
  update public.conversations set ended_at = now() where id = p_conv and ended_at is null;
end $$;
grant execute on function public.end_conversation(uuid) to authenticated;

-- my_conversations now also surfaces ended_at (return shape changes → drop first).
drop function if exists public.my_conversations();
create function public.my_conversations()
returns table(id uuid, posting_id uuid, seeker_id uuid, posting_title text, company_name text,
              seeker_name text, last_message_at timestamptz, i_am_recruiter boolean, ended_at timestamptz)
language sql stable security definer set search_path = public as $$
  select c.id, c.posting_id, c.seeker_id,
         p.title      as posting_title,
         co.name      as company_name,
         pr.full_name as seeker_name,
         c.last_message_at,
         public.owns_posting(c.posting_id) as i_am_recruiter,
         c.ended_at
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

-- Daily purge of conversations ended more than 31 days ago (messages cascade).
select cron.schedule('purge-ended-chats', '0 3 * * *',
  $job$delete from public.conversations where ended_at is not null and ended_at < now() - interval '31 days'$job$);
