-- ============================================================================
-- GigCute — per-user theme preference.
-- Users can choose their visual theme in Settings. Default 'dark' preserves the
-- current experience for everyone; 'slate' is the opt-in light theme. Stored on
-- the profile so the choice follows the account across devices (logged-out users
-- fall back to a localStorage copy on the client).
-- ============================================================================
alter table public.profiles
  add column if not exists theme text not null default 'dark'
  check (theme in ('dark', 'slate'));
