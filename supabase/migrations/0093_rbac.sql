-- ============================================================================
-- GigCute ATS — role-based permissions.
-- Capability matrix by effective role (owner => admin):
--   view            everyone (any member)
--   interview       everyone — leave scorecards & notes
--   manage_pipeline admin/recruiter/coordinator/hiring_manager — move, reject, hire
--   manage_jobs     admin/recruiter — create/edit/delete postings
--   schedule        admin/recruiter/coordinator/hiring_manager — interviews
--   (manage_team is admin-only, enforced in 0092)
-- Enforced in the ATS RPCs and on the postings table.
-- ============================================================================

create or replace function public.company_role_of(p_company uuid)
returns text language sql stable security definer set search_path=public as $$
  select case
    when exists(select 1 from public.companies c where c.id=p_company and c.owner_id=auth.uid()) then 'admin'
    else (select member_role from public.company_members m where m.company_id=p_company and m.profile_id=auth.uid() limit 1)
  end;
$$;
grant execute on function public.company_role_of(uuid) to authenticated;

create or replace function public.company_can(p_company uuid, p_cap text)
returns boolean language sql stable security definer set search_path=public as $$
  select case coalesce(public.company_role_of(p_company),'')
    when 'admin'          then true
    when 'recruiter'      then p_cap in ('view','interview','manage_pipeline','manage_jobs','schedule')
    when 'coordinator'    then p_cap in ('view','interview','manage_pipeline','schedule')
    when 'hiring_manager' then p_cap in ('view','interview','manage_pipeline','schedule')
    when 'interviewer'    then p_cap in ('view','interview')
    else false
  end;
$$;
grant execute on function public.company_can(uuid, text) to authenticated;

-- The caller's role + capabilities for their company (UI gates off this).
create or replace function public.company_my_caps(p_company uuid default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_co uuid;
begin
  v_co := coalesce(p_company, (
    select id from public.companies where owner_id=auth.uid()
    union select company_id from public.company_members where profile_id=auth.uid() limit 1));
  if v_co is null then return null; end if;
  return jsonb_build_object('company_id', v_co, 'role', public.company_role_of(v_co),
    'manage_pipeline', public.company_can(v_co,'manage_pipeline'),
    'manage_jobs', public.company_can(v_co,'manage_jobs'),
    'manage_team', public.company_can(v_co,'manage_team'),
    'schedule', public.company_can(v_co,'schedule'));
end $$;
grant execute on function public.company_my_caps(uuid) to authenticated;

-- ---- postings: only manage_jobs roles may write; reads unchanged ----
drop policy if exists "postings: member write" on public.postings;
create policy "postings: insert jobs" on public.postings for insert with check (public.company_can(company_id,'manage_jobs'));
create policy "postings: update jobs" on public.postings for update using (public.company_can(company_id,'manage_jobs')) with check (public.company_can(company_id,'manage_jobs'));
create policy "postings: delete jobs" on public.postings for delete using (public.company_can(company_id,'manage_jobs'));

-- ---- ATS RPCs: enforce capabilities ----
create or replace function public.ats_move_stage(p_app uuid, p_stage uuid)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_co uuid; v_from uuid; v_cat stage_category;
begin
  select company_id, current_stage_id into v_co, v_from from public.applications where id=p_app;
  if v_co is null or not public.company_can(v_co,'manage_pipeline') then raise exception 'You don''t have permission to move candidates.'; end if;
  if not exists (select 1 from public.job_stages s join public.applications a on a.posting_id=s.posting_id where s.id=p_stage and a.id=p_app) then
    raise exception 'Stage does not belong to this posting.'; end if;
  select category into v_cat from public.job_stages where id=p_stage;
  update public.applications
     set current_stage_id=p_stage,
         status = case when v_cat='hired' then 'hired'::application_status
                       when status='hired' then 'active'::application_status else status end
   where id=p_app;
  insert into public.application_activities(company_id, application_id, actor_id, type, from_stage_id, to_stage_id)
    values (v_co, p_app, auth.uid(), 'stage_change', v_from, p_stage);
  return jsonb_build_object('id', p_app, 'stage_id', p_stage);
end $$;

create or replace function public.ats_set_status(p_app uuid, p_status text, p_reason text default null)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_co uuid; v_st application_status;
begin
  select company_id into v_co from public.applications where id=p_app;
  if v_co is null or not public.company_can(v_co,'manage_pipeline') then raise exception 'You don''t have permission to change candidate status.'; end if;
  begin v_st := p_status::application_status; exception when others then raise exception 'Invalid status %.', p_status; end;
  update public.applications
     set status=v_st,
         rejected_reason = case when v_st='rejected' then p_reason else null end,
         rejected_at     = case when v_st='rejected' then now() else null end
   where id=p_app;
  insert into public.application_activities(company_id, application_id, actor_id, type, body)
    values (v_co, p_app, auth.uid(),
            (case when v_st='rejected' then 'rejected' when v_st='hired' then 'hired'
                  when v_st='withdrawn' then 'withdrawn' else 'note' end)::ats_activity_type,
            case when v_st='rejected' then coalesce(nullif(p_reason,''),'Rejected') else null end);
  return jsonb_build_object('id', p_app, 'status', v_st);
end $$;

create or replace function public.ats_add_note(p_app uuid, p_body text)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_co uuid; v_id uuid;
begin
  select company_id into v_co from public.applications where id=p_app;
  if v_co is null or not public.company_can(v_co,'interview') then raise exception 'Not authorized.'; end if;
  if btrim(coalesce(p_body,''))='' then raise exception 'Empty note.'; end if;
  insert into public.application_activities(company_id, application_id, actor_id, type, body)
    values (v_co, p_app, auth.uid(), 'note', p_body) returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function public.ats_add_scorecard(p_app uuid, p_stage uuid, p_overall text, p_summary text, p_ratings jsonb default '{}')
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_co uuid; v_verdict scorecard_verdict; v_id uuid;
begin
  select company_id into v_co from public.applications where id=p_app;
  if v_co is null or not public.company_can(v_co,'interview') then raise exception 'Not authorized.'; end if;
  begin v_verdict := p_overall::scorecard_verdict; exception when others then raise exception 'Invalid verdict %.', p_overall; end;
  insert into public.scorecards(company_id, application_id, stage_id, interviewer_id, overall, summary, ratings, submitted_at)
    values (v_co, p_app, p_stage, auth.uid(), v_verdict, p_summary, coalesce(p_ratings,'{}'::jsonb), now()) returning id into v_id;
  insert into public.application_activities(company_id, application_id, actor_id, type, to_stage_id, body)
    values (v_co, p_app, auth.uid(), 'scorecard', p_stage, p_overall);
  return jsonb_build_object('id', v_id);
end $$;

-- ats_pipeline: include the viewer's role + capabilities so the UI can gate.
create or replace function public.ats_pipeline(p_posting uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_co uuid; result jsonb;
begin
  select company_id into v_co from public.postings where id=p_posting;
  if v_co is null or not public.is_company_member(v_co) then return null; end if;
  select jsonb_build_object(
    'posting', (select jsonb_build_object('id',p.id,'title',p.title,'status',p.status,'department',p.department,
                  'city',p.city,'location_type',p.location_type,'salary_min',p.salary_min,'salary_max',p.salary_max)
                from public.postings p where p.id=p_posting),
    'can', jsonb_build_object('role', public.company_role_of(v_co),
             'manage_pipeline', public.company_can(v_co,'manage_pipeline'),
             'manage_jobs', public.company_can(v_co,'manage_jobs'),
             'schedule', public.company_can(v_co,'schedule')),
    'stages', coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'category',s.category,'sort_order',s.sort_order) order by s.sort_order)
                from public.job_stages s where s.posting_id=p_posting), '[]'::jsonb),
    'applications', coalesce((select jsonb_agg(jsonb_build_object(
        'id', a.id, 'stage_id', a.current_stage_id, 'status', a.status, 'source', a.source, 'applied_at', a.applied_at,
        'days_in_stage', greatest(0, extract(day from now() - a.updated_at))::int,
        'scorecards', (select count(*) from public.scorecards sc where sc.application_id=a.id),
        'candidate', jsonb_build_object('id', pr.id, 'name', pr.full_name, 'headline', sp.headline,
           'photo', sp.photo_url, 'code', sp.public_code, 'exp_years', sp.exp_years)
      ) order by a.applied_at desc)
      from public.applications a
      join public.profiles pr on pr.id=a.candidate_id
      left join public.seeker_profiles sp on sp.profile_id=a.candidate_id
      where a.posting_id=p_posting and a.status in ('active','hired')), '[]'::jsonb)
  ) into result;
  return result;
end $$;
