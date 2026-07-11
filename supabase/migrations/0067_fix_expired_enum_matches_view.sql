-- ============================================================================
-- GigCute — two audit fixes (already applied to the live DB on 2026-07-10).
--
-- 1. posting_status enum was missing 'expired', but 0060's lifecycle uses it:
--    the nightly expire/purge crons errored on every run and posting_activate
--    (Publish / Repost) raised "invalid input value for enum". Add the value.
-- 2. public.matches (0001) was a definer-rights view granted to anon +
--    authenticated — it bypassed RLS on seeker_interest / recruiter_interest,
--    exposing the platform-wide match graph to any caller. security_invoker
--    makes the base tables' RLS apply to the caller: seekers still see their
--    own matches, verified posting owners theirs, everyone else nothing.
-- ============================================================================
alter type public.posting_status add value if not exists 'expired';

alter view public.matches set (security_invoker = true);
