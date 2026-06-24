-- ============================================================================
-- GigCute — role grants
-- Supabase's anon/authenticated roles need table/function privileges IN ADDITION
-- to the RLS policies. (When the schema is created via the SQL editor these
-- default grants aren't always applied.) RLS still governs which ROWS are
-- visible; these GRANTs just allow the roles to touch the tables at all.
-- ============================================================================

grant usage on schema public to anon, authenticated, service_role;

grant select, insert, update, delete on all tables in schema public to anon, authenticated, service_role;
grant usage, select on all sequences in schema public to anon, authenticated, service_role;
grant execute on all functions in schema public to anon, authenticated, service_role;

-- Apply the same to anything created later.
alter default privileges in schema public grant select, insert, update, delete on tables to anon, authenticated, service_role;
alter default privileges in schema public grant usage, select on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
