-- ============================================================================
-- GigCute — admin moderation actions for direct recruiter postings.
--
-- Complements admin_postings (read) with write actions: pause/resume (status)
-- and delete. Both is_admin()-gated and security definer, so an admin can act on
-- any posting regardless of the owner-scoped RLS on the postings table. Delete
-- relies on the ON DELETE CASCADE already defined on every posting child table
-- (views, interest, applications, conversations, screening questions, etc.).
-- ============================================================================

-- Set a posting's status. Accepts the real posting_status values only
-- (active/paused/closed/draft/expired); anything else is rejected. Returns the
-- posting's id + new status, or null for non-admins.
create or replace function public.admin_set_posting_status(p_id uuid, p_status text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_new posting_status; v_row record;
begin
  if not public.is_admin() then return null; end if;
  begin
    v_new := p_status::posting_status;
  exception when others then
    raise exception 'Invalid status %; expected active, paused, closed, draft, or expired.', p_status;
  end;
  update public.postings
     set status = v_new,
         published_at = case when v_new = 'active' and published_at is null then now() else published_at end,
         updated_at = now()
   where id = p_id
   returning id, status into v_row;
  if not found then raise exception 'Posting % not found.', p_id; end if;
  return jsonb_build_object('id', v_row.id, 'status', v_row.status);
end $$;

-- Permanently delete a posting. Cascades to all child rows (applications,
-- conversations, interest, views, screening questions, ...). Irreversible.
create or replace function public.admin_delete_posting(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_title text;
begin
  if not public.is_admin() then return null; end if;
  delete from public.postings where id = p_id returning title into v_title;
  if not found then raise exception 'Posting % not found.', p_id; end if;
  return jsonb_build_object('deleted', true, 'title', v_title);
end $$;

grant execute on function public.admin_set_posting_status(uuid, text) to authenticated;
grant execute on function public.admin_delete_posting(uuid) to authenticated;
