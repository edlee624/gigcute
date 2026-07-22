-- ============================================================================
-- GigCute — recruiter accounts require a corporate email address.
--
-- The corporate-domain machinery already existed (blocked_email_domains +
-- is_business_domain), but it only decided whether a company was auto-VERIFIED.
-- Nothing stopped a recruiter from signing up with gmail. Now handle_new_user
-- rejects the signup outright, so the rule holds even against direct API calls —
-- the client form pre-checks the domain first to show a friendly message.
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
  -- Recruiters must sign up with a corporate email: free/disposable providers
  -- (blocked_email_domains) are rejected. Raising here aborts the auth.users
  -- insert, so no account, profile, or confirmation email is produced.
  if v_role = 'recruiter'
     and not public.is_business_domain(lower(split_part(coalesce(new.email, ''), '@', 2))) then
    raise exception 'Recruiter accounts require a corporate email address.';
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

-- The signup form pre-checks the domain to show a friendly error before calling
-- signUp (the trigger's raise surfaces as an opaque "Database error saving new
-- user"). Security definer + anon grant is fine: it answers one boolean about a
-- domain string and reads nothing else.
grant execute on function public.is_business_domain(text) to anon, authenticated;
