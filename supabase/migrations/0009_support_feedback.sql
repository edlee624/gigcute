-- ============================================================================
-- GigCute — support tickets + chat feedback
-- ============================================================================

-- End-of-chat feedback (collected when a user ends a conversation).
create table public.chat_feedback (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid references public.conversations(id) on delete set null,
  rater_id        uuid references public.profiles(id) on delete set null,
  experience      text,   -- Great | Okay | Poor
  professionalism text,   -- Very professional | Professional | Unprofessional
  match_accuracy  text,   -- Spot on | Decent | Off
  note            text,
  created_at      timestamptz not null default now()
);
alter table public.chat_feedback enable row level security;
create policy "feedback: insert own" on public.chat_feedback for insert with check (rater_id = auth.uid());
create policy "feedback: own/admin read" on public.chat_feedback for select using (rater_id = auth.uid() or public.is_admin());

-- Support tickets: technical issues, or abuse reports about a person you chatted with.
create table public.support_tickets (
  id           uuid primary key default gen_random_uuid(),
  reporter_id  uuid references public.profiles(id) on delete set null,
  type         text not null,        -- 'technical' | 'abuse'
  about_name   text,                 -- for abuse: the reported person's display name
  about_id     uuid references public.profiles(id) on delete set null,
  details      text,
  status       text not null default 'open',   -- open | resolved | escalated
  created_at   timestamptz not null default now(),
  resolved_at  timestamptz,
  reviewed_by  uuid references public.profiles(id) on delete set null
);
alter table public.support_tickets enable row level security;
create policy "tickets: insert auth" on public.support_tickets for insert with check (auth.uid() is not null);
create policy "tickets: own/admin read" on public.support_tickets for select using (reporter_id = auth.uid() or public.is_admin());
create policy "tickets: admin update" on public.support_tickets for update using (public.is_admin());

-- Grants (anon/authenticated need these in addition to RLS, per migration 0006).
grant select, insert, update on public.chat_feedback   to authenticated;
grant select, insert, update on public.support_tickets to authenticated;
