-- ============================================================================
-- GigCute ATS — feed the pipeline from live GigCute interactions.
-- 0089 backfilled interest once; this makes it continuous: a seeker expressing
-- interest, a recruiter sourcing a candidate, or a recruiter inviting a candidate
-- to chat now auto-creates a pipeline application (idempotent) at the Applied
-- stage, so the kanban reflects real activity in real time.
-- ============================================================================

-- Idempotent "put this candidate on this job's pipeline". Returns the application
-- id (existing or new). SECURITY DEFINER so a seeker's own action can create the
-- application despite the recruiter-only RLS on applications.
create or replace function public.ats_ensure_application(
  p_company uuid, p_posting uuid, p_candidate uuid, p_source application_source, p_created_by uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_app uuid; v_stage uuid;
begin
  if p_company is null or p_posting is null or p_candidate is null then return null; end if;
  select id into v_app from public.applications where posting_id=p_posting and candidate_id=p_candidate;
  if v_app is not null then return v_app; end if;
  select id into v_stage from public.job_stages where posting_id=p_posting and category='applied' order by sort_order limit 1;
  insert into public.applications(company_id, posting_id, candidate_id, current_stage_id, source, created_by)
    values (p_company, p_posting, p_candidate, v_stage, p_source, p_created_by)
    on conflict (posting_id, candidate_id) do nothing
    returning id into v_app;
  if v_app is null then
    select id into v_app from public.applications where posting_id=p_posting and candidate_id=p_candidate;
  end if;
  return v_app;
end $$;

-- seeker expresses interest -> Applied
create or replace function public.seeker_interest_to_app() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_co uuid;
begin
  select company_id into v_co from public.postings where id=new.posting_id;
  perform public.ats_ensure_application(v_co, new.posting_id, new.seeker_id, 'applied', null);
  return new;
end $$;
drop trigger if exists seeker_interest_to_app_trg on public.seeker_interest;
create trigger seeker_interest_to_app_trg after insert on public.seeker_interest
  for each row execute function public.seeker_interest_to_app();

-- recruiter sources a candidate -> Applied (source=sourced)
create or replace function public.recruiter_interest_to_app() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_co uuid;
begin
  select company_id into v_co from public.postings where id=new.posting_id;
  perform public.ats_ensure_application(v_co, new.posting_id, new.seeker_id, 'sourced', new.created_by);
  return new;
end $$;
drop trigger if exists recruiter_interest_to_app_trg on public.recruiter_interest;
create trigger recruiter_interest_to_app_trg after insert on public.recruiter_interest
  for each row execute function public.recruiter_interest_to_app();

-- recruiter invites a candidate to chat -> Applied (sourced) + an "Invited to chat" note
create or replace function public.invite_to_app() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_co uuid; v_app uuid;
begin
  if new.posting_id is null then return new; end if;
  select company_id into v_co from public.postings where id=new.posting_id;
  v_app := public.ats_ensure_application(v_co, new.posting_id, new.seeker_id, 'sourced', null);
  if v_app is not null then
    insert into public.application_activities(company_id, application_id, actor_id, type, body)
      values (v_co, v_app, auth.uid(), 'note', 'Invited to chat');
  end if;
  return new;
end $$;
drop trigger if exists invite_to_app_trg on public.invites;
create trigger invite_to_app_trg after insert on public.invites
  for each row execute function public.invite_to_app();

-- one-time backfill of existing invites (0089 already did seeker/recruiter interest)
insert into public.applications (company_id, posting_id, candidate_id, current_stage_id, source, applied_at)
select p.company_id, i.posting_id, i.seeker_id,
       (select id from public.job_stages s where s.posting_id=i.posting_id and s.category='applied' limit 1),
       'sourced', i.created_at
from public.invites i join public.postings p on p.id=i.posting_id
where i.posting_id is not null
on conflict (posting_id, candidate_id) do nothing;
