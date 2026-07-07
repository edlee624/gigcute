-- ============================================================================
-- GigCute — create a seeker_profiles row at signup
-- handle_new_user() previously created only the profiles row. The public
-- profile page resolves via public_profile() (migration 0014), which returns
-- null when no seeker_profiles row exists, so a seeker who logs in before
-- completing onboarding hit a dead-end "Profile not available". This became
-- reachable once email confirmation was enforced (signup no longer flows
-- straight into onboarding — the user confirms via email and logs in fresh).
--
-- Fix: the trigger now also inserts a seeker_profiles row for seekers, and we
-- backfill any existing seekers that are missing one. Only profile_id is
-- required (is_visible defaults true), so the profile page renders immediately
-- and the user can fill it in via Edit.
-- ============================================================================
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_role user_role;
begin
  begin
    v_role := (new.raw_user_meta_data->>'role')::user_role;
  exception when others then
    v_role := 'seeker';
  end;
  if v_role is null or v_role = 'admin' then
    v_role := 'seeker';
  end if;
  insert into public.profiles (id, email, full_name, role)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name',''), v_role);
  -- Seekers need a seeker_profiles row so their profile page resolves right after
  -- signup, even before onboarding runs (esp. now that email confirmation gates it).
  if v_role = 'seeker' then
    insert into public.seeker_profiles (profile_id) values (new.id)
    on conflict (profile_id) do nothing;
  end if;
  return new;
end; $$;

-- Backfill: seekers created before this migration that have no seeker_profiles row.
insert into public.seeker_profiles (profile_id)
select p.id from public.profiles p
left join public.seeker_profiles sp on sp.profile_id = p.id
where p.role = 'seeker' and sp.profile_id is null
on conflict (profile_id) do nothing;
