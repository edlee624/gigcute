-- ============================================================================
-- GigCute ATS — Phase 1 / M2: server RPCs for the recruiter pipeline.
-- All SECURITY DEFINER + is_company_member()-gated; mutations stamp auth.uid()
-- as the actor and append to application_activities.
-- ============================================================================

-- Recruiter's jobs with pipeline counts.
create or replace function public.ats_jobs()
returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(j order by created_at desc), '[]'::jsonb) from (
    select p.created_at, jsonb_build_object(
      'id', p.id, 'title', p.title, 'status', p.status, 'department', p.department,
      'company', co.name, 'created_at', p.created_at,
      'active', (select count(*) from public.applications a where a.posting_id=p.id and a.status='active'),
      'hired',  (select count(*) from public.applications a where a.posting_id=p.id and a.status='hired'),
      'by_stage', coalesce((select jsonb_object_agg(s.name, s.cnt) from (
          select st.name, st.sort_order,
                 (select count(*) from public.applications a where a.posting_id=p.id and a.current_stage_id=st.id and a.status in ('active','hired')) cnt
          from public.job_stages st where st.posting_id=p.id order by st.sort_order) s), '{}'::jsonb)
    ) as j
    from public.postings p
    left join public.companies co on co.id=p.company_id
    where public.is_company_member(p.company_id)
  ) t(created_at, j);
$$;
grant execute on function public.ats_jobs() to authenticated;

-- Full board for one job: posting + ordered stages + active/hired applications.
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
grant execute on function public.ats_pipeline(uuid) to authenticated;

-- Move an application to another stage on the same posting (logs stage_change).
create or replace function public.ats_move_stage(p_app uuid, p_stage uuid)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_co uuid; v_from uuid; v_cat stage_category;
begin
  select company_id, current_stage_id into v_co, v_from from public.applications where id=p_app;
  if v_co is null or not public.is_company_member(v_co) then raise exception 'Not authorized.'; end if;
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
grant execute on function public.ats_move_stage(uuid, uuid) to authenticated;

-- Set application status (reject / hire / withdraw / reactivate); logs it.
create or replace function public.ats_set_status(p_app uuid, p_status text, p_reason text default null)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_co uuid; v_st application_status;
begin
  select company_id into v_co from public.applications where id=p_app;
  if v_co is null or not public.is_company_member(v_co) then raise exception 'Not authorized.'; end if;
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
grant execute on function public.ats_set_status(uuid, text, text) to authenticated;

-- Add a note to the timeline.
create or replace function public.ats_add_note(p_app uuid, p_body text)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_co uuid; v_id uuid;
begin
  select company_id into v_co from public.applications where id=p_app;
  if v_co is null or not public.is_company_member(v_co) then raise exception 'Not authorized.'; end if;
  if btrim(coalesce(p_body,''))='' then raise exception 'Empty note.'; end if;
  insert into public.application_activities(company_id, application_id, actor_id, type, body)
    values (v_co, p_app, auth.uid(), 'note', p_body) returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;
grant execute on function public.ats_add_note(uuid, text) to authenticated;

-- Submit a scorecard (logs a scorecard activity).
create or replace function public.ats_add_scorecard(p_app uuid, p_stage uuid, p_overall text, p_summary text, p_ratings jsonb default '{}')
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_co uuid; v_verdict scorecard_verdict; v_id uuid;
begin
  select company_id into v_co from public.applications where id=p_app;
  if v_co is null or not public.is_company_member(v_co) then raise exception 'Not authorized.'; end if;
  begin v_verdict := p_overall::scorecard_verdict; exception when others then raise exception 'Invalid verdict %.', p_overall; end;
  insert into public.scorecards(company_id, application_id, stage_id, interviewer_id, overall, summary, ratings, submitted_at)
    values (v_co, p_app, p_stage, auth.uid(), v_verdict, p_summary, coalesce(p_ratings,'{}'::jsonb), now()) returning id into v_id;
  insert into public.application_activities(company_id, application_id, actor_id, type, to_stage_id, body)
    values (v_co, p_app, auth.uid(), 'scorecard', p_stage, p_overall);
  return jsonb_build_object('id', v_id);
end $$;
grant execute on function public.ats_add_scorecard(uuid, uuid, text, text, jsonb) to authenticated;

-- Full candidate detail for the drawer: application + profile + screening + timeline + scorecards.
create or replace function public.ats_candidate(p_app uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_co uuid; v_posting uuid; v_cand uuid; result jsonb;
begin
  select company_id, posting_id, candidate_id into v_co, v_posting, v_cand from public.applications where id=p_app;
  if v_co is null or not public.is_company_member(v_co) then return null; end if;
  select jsonb_build_object(
    'application', (select jsonb_build_object('id',a.id,'status',a.status,'source',a.source,'stage_id',a.current_stage_id,
                      'applied_at',a.applied_at,'rejected_reason',a.rejected_reason) from public.applications a where a.id=p_app),
    'candidate', (select jsonb_build_object('id',pr.id,'name',pr.full_name,'email',pr.email,
                      'headline',sp.headline,'photo',sp.photo_url,'code',sp.public_code,'linkedin',sp.linkedin_url,
                      'exp_years',sp.exp_years,'skills',sp.skills,'work_setup',sp.work_setup,
                      'personality_type',sp.personality_type,'strengths',sp.strengths,
                      'desired_titles',sp.desired_titles,'desired_salary_min',sp.desired_salary_min,'desired_salary_max',sp.desired_salary_max)
                   from public.profiles pr left join public.seeker_profiles sp on sp.profile_id=pr.id where pr.id=v_cand),
    'screening', coalesce((select jsonb_agg(jsonb_build_object('q',q.question_text,'a',aa.answer_text,'meets',aa.meets_essential,'essential',q.essential) order by q.sort_order)
                   from public.application_answers aa join public.screening_questions q on q.id=aa.question_id
                   where aa.posting_id=v_posting and aa.seeker_id=v_cand), '[]'::jsonb),
    'activities', coalesce((select jsonb_agg(jsonb_build_object('type',ac.type,'body',ac.body,'from',fs.name,'to',ts.name,
                      'actor',apr.full_name,'at',ac.created_at) order by ac.created_at desc)
                   from public.application_activities ac
                   left join public.job_stages fs on fs.id=ac.from_stage_id
                   left join public.job_stages ts on ts.id=ac.to_stage_id
                   left join public.profiles apr on apr.id=ac.actor_id
                   where ac.application_id=p_app), '[]'::jsonb),
    'scorecards', coalesce((select jsonb_agg(jsonb_build_object('overall',sc.overall,'summary',sc.summary,'ratings',sc.ratings,
                      'interviewer',ipr.full_name,'stage',st.name,'at',sc.submitted_at) order by sc.created_at desc)
                   from public.scorecards sc
                   left join public.profiles ipr on ipr.id=sc.interviewer_id
                   left join public.job_stages st on st.id=sc.stage_id
                   where sc.application_id=p_app), '[]'::jsonb)
  ) into result;
  return result;
end $$;
grant execute on function public.ats_candidate(uuid) to authenticated;
