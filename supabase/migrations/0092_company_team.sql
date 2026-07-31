-- ============================================================================
-- GigCute for orgs — company teams: an admin provisions recruiter seats.
-- The company creator is the owner/admin; they invite teammates by email and
-- assign roles. Invited emails auto-join on signup (bypassing the corporate-email
-- gate, since an invite is a trust signal). Roles: admin / recruiter / coordinator
-- / interviewer / hiring_manager. Builds on company_members (already exists).
-- ============================================================================

-- Make (company_id, profile_id) upsertable.
create unique index if not exists company_members_uq on public.company_members(company_id, profile_id);

-- Admin = company owner OR a member with role 'admin'.
create or replace function public.is_company_admin(p_company uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists (
    select 1 from public.companies c where c.id = p_company and c.owner_id = auth.uid()
    union
    select 1 from public.company_members m where m.company_id = p_company and m.profile_id = auth.uid() and m.member_role = 'admin'
  );
$$;
grant execute on function public.is_company_admin(uuid) to authenticated;

-- Pending/accepted/revoked invites for people who aren't yet users.
create table if not exists public.company_member_invites (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  email text not null,
  role text not null default 'recruiter',
  invited_by uuid references public.profiles(id) on delete set null,
  status text not null default 'pending' check (status in ('pending','accepted','revoked')),
  created_at timestamptz not null default now(),
  accepted_at timestamptz
);
create unique index if not exists company_member_invites_pending_uq
  on public.company_member_invites(company_id, lower(email)) where status = 'pending';

alter table public.company_member_invites enable row level security;
revoke all on public.company_member_invites from anon;
grant select on public.company_member_invites to authenticated;
drop policy if exists cmi_member_read on public.company_member_invites;
create policy cmi_member_read on public.company_member_invites for select
  using (public.is_company_member(company_id));

-- Invite-aware signup: replaces handle_new_user. An email with a pending invite
-- joins that company on signup and skips the corporate-email requirement.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_role user_role; v_invite record;
begin
  begin v_role := (new.raw_user_meta_data->>'role')::user_role; exception when others then v_role := 'seeker'; end;
  if v_role is null or v_role = 'admin' then v_role := 'seeker'; end if;

  select * into v_invite from public.company_member_invites
   where lower(email) = lower(new.email) and status = 'pending'
   order by created_at desc limit 1;

  if v_role = 'recruiter' and v_invite.id is null
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

-- ---- RPCs (all is_company_admin-gated for writes; reads for any member) ----
create or replace function public.company_team(p_company uuid default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_co uuid; result jsonb;
begin
  v_co := coalesce(p_company, (
    select id from public.companies where owner_id = auth.uid()
    union
    select company_id from public.company_members where profile_id = auth.uid()
    limit 1));
  if v_co is null or not public.is_company_member(v_co) then return null; end if;
  select jsonb_build_object(
    'company', (select jsonb_build_object('id',c.id,'name',c.name,'domain',c.email_domain,'plan',c.plan) from public.companies c where c.id=v_co),
    'is_admin', public.is_company_admin(v_co),
    'members', coalesce((
      select jsonb_agg(to_jsonb(m) order by m.is_owner desc, m.name) from (
        select pr.id as profile_id, pr.full_name as name, pr.email, 'owner' as role, true as is_owner
        from public.companies c join public.profiles pr on pr.id=c.owner_id where c.id=v_co
        union all
        select pr.id, pr.full_name, pr.email, coalesce(mm.member_role,'recruiter'), false
        from public.company_members mm join public.profiles pr on pr.id=mm.profile_id
        where mm.company_id=v_co and pr.id <> (select owner_id from public.companies where id=v_co)
      ) m
    ), '[]'::jsonb),
    'invites', coalesce((
      select jsonb_agg(jsonb_build_object('id',i.id,'email',i.email,'role',i.role,'created_at',i.created_at) order by i.created_at desc)
      from public.company_member_invites i where i.company_id=v_co and i.status='pending'
    ), '[]'::jsonb)
  ) into result;
  return result;
end $$;
grant execute on function public.company_team(uuid) to authenticated;

create or replace function public.company_invite_member(p_company uuid, p_email text, p_role text default 'recruiter')
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_email text; v_uid uuid; v_role text;
begin
  if not public.is_company_admin(p_company) then raise exception 'Only a company admin can invite teammates.'; end if;
  v_email := lower(btrim(coalesce(p_email,'')));
  if v_email = '' or position('@' in v_email) = 0 then raise exception 'Enter a valid email address.'; end if;
  v_role := coalesce(nullif(btrim(p_role),''),'recruiter');
  if v_role not in ('admin','recruiter','coordinator','interviewer','hiring_manager') then raise exception 'Invalid role.'; end if;
  select id into v_uid from public.profiles where lower(email)=v_email limit 1;
  if v_uid is not null then
    insert into public.company_members(company_id, profile_id, member_role)
    values (p_company, v_uid, v_role) on conflict (company_id, profile_id) do update set member_role=excluded.member_role;
    return jsonb_build_object('status','added','email',v_email,'role',v_role);
  end if;
  insert into public.company_member_invites(company_id, email, role, invited_by, status)
  values (p_company, v_email, v_role, auth.uid(), 'pending')
  on conflict (company_id, lower(email)) where status='pending' do update set role=excluded.role;
  return jsonb_build_object('status','invited','email',v_email,'role',v_role);
end $$;
grant execute on function public.company_invite_member(uuid, text, text) to authenticated;

create or replace function public.company_set_role(p_company uuid, p_profile uuid, p_role text)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
begin
  if not public.is_company_admin(p_company) then raise exception 'Only an admin can change roles.'; end if;
  if p_profile = (select owner_id from public.companies where id=p_company) then raise exception 'The owner''s role can''t be changed.'; end if;
  if p_role not in ('admin','recruiter','coordinator','interviewer','hiring_manager') then raise exception 'Invalid role.'; end if;
  update public.company_members set member_role=p_role where company_id=p_company and profile_id=p_profile;
  if not found then raise exception 'That person is not a team member.'; end if;
  return jsonb_build_object('ok',true);
end $$;
grant execute on function public.company_set_role(uuid, uuid, text) to authenticated;

create or replace function public.company_remove_member(p_company uuid, p_profile uuid)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
begin
  if not public.is_company_admin(p_company) then raise exception 'Only an admin can remove members.'; end if;
  if p_profile = (select owner_id from public.companies where id=p_company) then raise exception 'The owner can''t be removed.'; end if;
  delete from public.company_members where company_id=p_company and profile_id=p_profile;
  return jsonb_build_object('ok',true);
end $$;
grant execute on function public.company_remove_member(uuid, uuid) to authenticated;

create or replace function public.company_revoke_invite(p_invite uuid)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_co uuid;
begin
  select company_id into v_co from public.company_member_invites where id=p_invite;
  if v_co is null or not public.is_company_admin(v_co) then raise exception 'Not authorized.'; end if;
  update public.company_member_invites set status='revoked' where id=p_invite;
  return jsonb_build_object('ok',true);
end $$;
grant execute on function public.company_revoke_invite(uuid) to authenticated;

-- Called on login to accept any pending invites for the signed-in user's email.
create or replace function public.company_claim_invites()
returns int language plpgsql volatile security definer set search_path=public as $$
declare v_email text; v_uid uuid; v_n int := 0; r record;
begin
  v_uid := auth.uid(); if v_uid is null then return 0; end if;
  select lower(email) into v_email from public.profiles where id=v_uid;
  if v_email is null then return 0; end if;
  for r in select * from public.company_member_invites where lower(email)=v_email and status='pending' loop
    insert into public.company_members(company_id, profile_id, member_role)
    values (r.company_id, v_uid, r.role) on conflict (company_id, profile_id) do update set member_role=excluded.member_role;
    update public.company_member_invites set status='accepted', accepted_at=now() where id=r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
grant execute on function public.company_claim_invites() to authenticated;
