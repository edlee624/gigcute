-- ============================================================================
-- GigCute — my_conversations RPC
-- Returns the caller's conversations with the PEER's display name resolved
-- server-side: the seeker's name (from profiles, normally self/admin-only) is
-- exposed to the recruiter they're already conversing with, and vice-versa.
-- security definer + the participant check keep it from leaking anything the
-- caller couldn't already reach. `i_am_recruiter` lets the UI pick the title.
-- ============================================================================
create or replace function public.my_conversations()
returns table(
  id uuid,
  posting_id uuid,
  seeker_id uuid,
  posting_title text,
  company_name text,
  seeker_name text,
  last_message_at timestamptz,
  i_am_recruiter boolean
)
language sql stable security definer set search_path = public as $$
  select c.id, c.posting_id, c.seeker_id,
         p.title          as posting_title,
         co.name          as company_name,
         pr.full_name     as seeker_name,
         c.last_message_at,
         public.owns_posting(c.posting_id) as i_am_recruiter
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
