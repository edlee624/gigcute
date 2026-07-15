-- ============================================================================
-- GigCute — user → admin feedback channel (the feedback loop).
--   feedback              : messages/bug reports/ideas from users (or anon).
--   admin_feedback_reply  : admin posts a reply -> marks resolved AND delivers
--                           the reply to the user's in-app inbox (user_notifications),
--                           so the loop closes without email. Anon submitters
--                           (no user_id) leave an email for a manual reply.
-- Submitting is open to anyone; reading/answering is admin-only (own rows are
-- also readable by the submitter so they can see the reply history).
-- ============================================================================
create table if not exists public.feedback (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references public.profiles(id) on delete set null,
  email       text,
  category    text not null default 'general',           -- 'bug' | 'idea' | 'general'
  message     text not null check (char_length(message) between 1 and 4000),
  page        text,                                        -- path/context at submit time
  status      text not null default 'new',                -- 'new' | 'read' | 'resolved'
  admin_reply text,
  replied_at  timestamptz,
  reviewed_by uuid references public.profiles(id),
  created_at  timestamptz not null default now()
);
create index if not exists feedback_status_idx on public.feedback (status, created_at desc);

alter table public.feedback enable row level security;

-- Submit: anyone (logged-in or anonymous). Can't spoof someone else's user_id.
drop policy if exists "feedback insert" on public.feedback;
create policy "feedback insert" on public.feedback for insert
  with check (user_id is null or user_id = auth.uid());
grant insert on public.feedback to anon, authenticated;

-- Read: admins see everything; a submitter can see their own rows (replies).
drop policy if exists "feedback admin read" on public.feedback;
create policy "feedback admin read" on public.feedback for select using (public.is_admin());
drop policy if exists "feedback own read" on public.feedback;
create policy "feedback own read" on public.feedback for select using (user_id = auth.uid());
grant select on public.feedback to authenticated;

-- Update: admins only (status changes; replies go through the RPC below).
drop policy if exists "feedback admin update" on public.feedback;
create policy "feedback admin update" on public.feedback for update
  using (public.is_admin()) with check (public.is_admin());
grant update on public.feedback to authenticated;

-- ---- admin reply: resolve + deliver in-app --------------------------------
create or replace function public.admin_feedback_reply(p_id uuid, p_reply text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare fb public.feedback; me uuid := auth.uid();
begin
  if not public.is_admin() then return null; end if;
  if coalesce(btrim(p_reply), '') = '' then raise exception 'reply required'; end if;

  update public.feedback
     set admin_reply = btrim(p_reply), replied_at = now(), status = 'resolved', reviewed_by = me
   where id = p_id
  returning * into fb;
  if not found then raise exception 'feedback not found'; end if;

  -- Close the loop in-app when we know who sent it.
  if fb.user_id is not null then
    insert into public.user_notifications (user_id, kind, title, body)
    values (fb.user_id, 'feedback_reply', 'Reply from the GigCute team', btrim(p_reply));
  end if;

  return jsonb_build_object('delivered_in_app', fb.user_id is not null, 'email', fb.email);
end $$;
grant execute on function public.admin_feedback_reply(uuid, text) to authenticated;
