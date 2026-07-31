-- ============================================================================
-- GigCute ATS — interview scheduling (Phase 2).
-- Schedule an interview on an application: when, duration, interviewer, location/
-- link, notes. Reads for any member; scheduling/cancel gated by the 'schedule'
-- capability. Each action logs to the candidate timeline.
-- ============================================================================

create table if not exists public.interviews (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  stage_id uuid references public.job_stages(id) on delete set null,
  scheduled_at timestamptz not null,
  duration_min int not null default 45,
  interviewer_id uuid references public.profiles(id) on delete set null,
  location text,
  notes text,
  status text not null default 'scheduled' check (status in ('scheduled','completed','canceled')),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists interviews_app_idx on public.interviews(application_id, scheduled_at);

alter table public.interviews enable row level security;
revoke all on public.interviews from anon;
grant select, insert, update, delete on public.interviews to authenticated;
drop policy if exists interviews_read on public.interviews;
create policy interviews_read on public.interviews for select using (public.is_company_member(company_id));
drop policy if exists interviews_write on public.interviews;
create policy interviews_write on public.interviews for all
  using (public.company_can(company_id,'schedule')) with check (public.company_can(company_id,'schedule'));

create or replace function public.ats_schedule_interview(p_app uuid, p_stage uuid, p_when timestamptz, p_duration int, p_interviewer uuid, p_location text, p_notes text)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_co uuid; v_id uuid; v_iname text;
begin
  select company_id into v_co from public.applications where id=p_app;
  if v_co is null or not public.company_can(v_co,'schedule') then raise exception 'You don''t have permission to schedule interviews.'; end if;
  if p_when is null then raise exception 'Pick a date and time.'; end if;
  insert into public.interviews(company_id, application_id, stage_id, scheduled_at, duration_min, interviewer_id, location, notes, created_by)
    values (v_co, p_app, p_stage, p_when, coalesce(nullif(p_duration,0),45), p_interviewer, nullif(btrim(coalesce(p_location,'')),''), nullif(btrim(coalesce(p_notes,'')),''), auth.uid())
    returning id into v_id;
  select full_name into v_iname from public.profiles where id=p_interviewer;
  insert into public.application_activities(company_id, application_id, actor_id, type, body)
    values (v_co, p_app, auth.uid(), 'note',
            'Interview scheduled with ' || coalesce(nullif(v_iname,''),'the team') ||
            ' for ' || to_char(p_when at time zone 'UTC','Mon DD, HH24:MI') || ' UTC');
  return jsonb_build_object('id', v_id);
end $$;
grant execute on function public.ats_schedule_interview(uuid, uuid, timestamptz, int, uuid, text, text) to authenticated;

create or replace function public.ats_interviews(p_app uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_co uuid;
begin
  select company_id into v_co from public.applications where id=p_app;
  if v_co is null or not public.is_company_member(v_co) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
     'id', i.id, 'scheduled_at', i.scheduled_at, 'duration_min', i.duration_min,
     'interviewer', pr.full_name, 'location', i.location, 'notes', i.notes, 'status', i.status, 'stage', st.name)
     order by i.scheduled_at)
   from public.interviews i
   left join public.profiles pr on pr.id=i.interviewer_id
   left join public.job_stages st on st.id=i.stage_id
   where i.application_id=p_app and i.status <> 'canceled'), '[]'::jsonb);
end $$;
grant execute on function public.ats_interviews(uuid) to authenticated;

create or replace function public.ats_cancel_interview(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_co uuid; v_app uuid;
begin
  select company_id, application_id into v_co, v_app from public.interviews where id=p_id;
  if v_co is null or not public.company_can(v_co,'schedule') then raise exception 'Not authorized.'; end if;
  update public.interviews set status='canceled' where id=p_id;
  insert into public.application_activities(company_id, application_id, actor_id, type, body)
    values (v_co, v_app, auth.uid(), 'note', 'Interview canceled');
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.ats_cancel_interview(uuid) to authenticated;
