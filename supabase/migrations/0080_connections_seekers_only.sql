-- ============================================================================
-- GigCute — connections are seeker ↔ seeker ONLY (exclude recruiters entirely).
-- Product decision: recruiters must not connect with seekers, even if a recruiter
-- account also has a seeker_profile row. So the eligibility gate moves from
-- "has a seeker profile" to "is a seeker account" (profiles.role = 'seeker').
-- is_seeker() gates connection inserts + connection_status via RLS/RPC (0079),
-- so this single redefinition tightens the whole feature.
-- ============================================================================
create or replace function public.is_seeker(uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = uid and role = 'seeker');
$$;
