-- ============================================================================
-- GigCute — restrict feedback submission to signed-in users only.
-- Previously anyone (incl. anonymous) could submit; product decision is to
-- gate the feedback channel behind auth, with the user's account email
-- autofilled. Enforce it at the DB: only `authenticated` may insert, and the
-- row must be attributed to the caller (user_id = auth.uid(), never null).
-- ============================================================================
drop policy if exists "feedback insert" on public.feedback;
create policy "feedback insert" on public.feedback for insert
  to authenticated with check (user_id = auth.uid());

-- Anon has no read policy anyway (RLS blocks it), but drop the default grant too.
revoke insert, select on public.feedback from anon;
