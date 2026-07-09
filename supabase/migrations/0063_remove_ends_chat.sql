-- ============================================================================
-- GigCute — "Remove" on an interested candidate should also END any open chat.
-- dismiss_candidate gains an optional p_end_chat flag:
--   * Remove button           -> p_end_chat = true  (sever ties: dismiss +
--                                delete invite + archive the conversation)
--   * Message-and-clear path  -> p_end_chat = false (just clear from the list;
--                                the chat is being OPENED, not ended)
-- Drop the old 2-arg version first so there's a single, unambiguous function.
-- ============================================================================
drop function if exists public.dismiss_candidate(uuid, uuid);

create or replace function public.dismiss_candidate(p_posting uuid, p_seeker uuid, p_end_chat boolean default false)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.owns_posting(p_posting) then return; end if;
  insert into public.posting_dismissed (posting_id, seeker_id, created_by)
  values (p_posting, p_seeker, auth.uid())
  on conflict (posting_id, seeker_id) do nothing;
  -- removing a candidate also withdraws any invite to them for this posting
  delete from public.invites where posting_id = p_posting and seeker_id = p_seeker;
  -- and, when asked, archives any open conversation with them (auto-deletes in 31 days)
  if p_end_chat then
    update public.conversations
       set ended_at = now()
     where posting_id = p_posting and seeker_id = p_seeker and ended_at is null;
  end if;
end $$;
grant execute on function public.dismiss_candidate(uuid, uuid, boolean) to authenticated;
