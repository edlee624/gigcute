-- ============================================================================
-- GigCute — per-account "GigCute intro" super-invite tracking
-- A new account sees the GigCute new-user intro once; this flag (updated by the
-- user via the existing profiles self-update RLS) keeps it from reappearing
-- across sessions/devices.
-- ============================================================================
alter table public.profiles
  add column if not exists intro_seen boolean not null default false;
