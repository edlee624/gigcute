-- ============================================================================
-- GigCute — user_prefs: per-user preferences (saved job-board filters, etc.)
-- One row per user holding a free-form jsonb blob, private to that user, so
-- filter selections persist across logins and devices.
-- ============================================================================
create table if not exists public.user_prefs (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  prefs      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.user_prefs enable row level security;

drop policy if exists "user_prefs: own" on public.user_prefs;
create policy "user_prefs: own" on public.user_prefs for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select, insert, update, delete on public.user_prefs to authenticated;
