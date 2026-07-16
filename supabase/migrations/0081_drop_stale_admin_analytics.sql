-- ============================================================================
-- GigCute — drop the dead 0-arg admin_analytics() overload.
-- Two overloads existed: admin_analytics() and
-- admin_analytics(p_days int default null, p_from date default null, p_to date default null).
-- Every caller goes through the 3-arg version (the client always sends p_days,
-- using p_days => null for "all time"), so the 0-arg one is unused — and keeping
-- both makes a no-argument call ambiguous (PostgREST PGRST203). Drop the dead one.
-- ============================================================================
drop function if exists public.admin_analytics();
