-- ============================================================================
-- GigCute — role security hardening
-- Closes two privilege-escalation paths around the admin role:
--   1) Signup metadata could request role='admin' (handle_new_user trusted it).
--   2) The profiles self-update policy let a user change their own role.
-- After this, 'admin' can only be granted server-side (SQL editor / service_role)
-- or by an existing admin — never by a normal user or at signup.
-- ============================================================================

-- 1) Never accept 'admin' (or invalid) role from signup metadata.
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
  return new;
end; $$;

-- 2) Prevent non-admins from changing their own role via UPDATE.
--    auth.uid() is null for server-side / SQL-editor / service_role calls, so
--    bootstrapping the first admin via the SQL editor still works.
create or replace function public.guard_profile_role()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.role is distinct from old.role then
    if not (public.is_admin() or auth.uid() is null) then
      new.role := old.role;   -- silently ignore unauthorized role changes
    end if;
  end if;
  return new;
end; $$;

drop trigger if exists profile_role_guard on public.profiles;
create trigger profile_role_guard
  before update on public.profiles
  for each row execute function public.guard_profile_role();
