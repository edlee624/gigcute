-- ============================================================================
-- GigCute — independent-recruiter signups.
-- Recruiter accounts still require a corporate email BY DEFAULT (companies), but
-- an independent recruiter (raw_user_meta_data.account_type = 'independent') may
-- sign up with any email and gets a solo workspace. Invited teammates already
-- bypass the gate. Everything else in handle_new_user is unchanged.
-- ============================================================================
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_role user_role; v_invite record;
begin
  begin v_role := (new.raw_user_meta_data->>'role')::user_role; exception when others then v_role := 'seeker'; end;
  if v_role is null or v_role = 'admin' then v_role := 'seeker'; end if;

  select * into v_invite from public.company_member_invites
   where lower(email) = lower(new.email) and status = 'pending'
   order by created_at desc limit 1;

  -- Corporate-email gate: skipped for invited teammates and independent recruiters.
  if v_role = 'recruiter'
     and v_invite.id is null
     and (new.raw_user_meta_data->>'account_type') is distinct from 'independent'
     and not public.is_business_domain(lower(split_part(coalesce(new.email, ''), '@', 2))) then
    raise exception 'Recruiter accounts require a corporate email address.';
  end if;

  insert into public.profiles (id, email, full_name, role)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name',''), v_role);

  if v_role = 'seeker' then
    insert into public.seeker_profiles (profile_id) values (new.id) on conflict (profile_id) do nothing;
  end if;

  if v_role = 'recruiter' and v_invite.id is not null then
    insert into public.company_members (company_id, profile_id, member_role)
    values (v_invite.company_id, new.id, v_invite.role)
    on conflict (company_id, profile_id) do update set member_role = excluded.member_role;
    update public.company_member_invites set status='accepted', accepted_at=now() where id = v_invite.id;
  end if;

  return new;
end; $$;
