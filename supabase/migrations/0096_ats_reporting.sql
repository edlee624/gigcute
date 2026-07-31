-- ============================================================================
-- GigCute ATS — Phase 2: reporting for HR management / leaders.
--
-- Company-scoped analytics over the pipeline. All SECURITY DEFINER + STABLE,
-- gated by is_company_member (aggregate reads only; no per-candidate PII beyond
-- what the board already shows). Diversity is admin-only and small-cell
-- suppressed, reusing the eeo_responses firewall (recruiters never read rows).
--
-- Each RPC resolves the caller's company (explicit p_company, else owned, else
-- first membership) and accepts an optional [p_from, p_to) date window; null =
-- all time. Returns jsonb so the client renders without extra shaping.
--
--   ats_report_overview     headline KPIs (open reqs, candidates, hires, TTH...)
--   ats_report_funnel       stage funnel + stage-to-stage conversion
--   ats_report_velocity     time-to-hire stats + avg dwell per stage
--   ats_report_sources      candidates & hires by source, hire rate
--   ats_report_recruiters   per-team-member productivity
--   ats_report_jobs         per-requisition status
--   ats_report_diversity    admin-only aggregate EEO (min cell 5)
-- ============================================================================

-- Resolve the company a report should run for, authorizing the caller.
create or replace function public.ats_report_company(p_company uuid)
returns uuid language sql stable security definer set search_path=public as $$
  select v.co from (
    select coalesce(
      p_company,
      (select id from public.companies where owner_id = auth.uid() order by created_at limit 1),
      (select company_id from public.company_members where profile_id = auth.uid() limit 1)
    ) as co
  ) v
  where v.co is not null and public.is_company_member(v.co);
$$;
grant execute on function public.ats_report_company(uuid) to authenticated;

-- Canonical stage-category ordering, reused across reports.
create or replace function public.ats_cat_rank(p text)
returns int language sql immutable as $$
  select case p when 'applied' then 1 when 'screen' then 2 when 'interview' then 3
                when 'offer' then 4 when 'hired' then 5 else 1 end;
$$;

-- ---------------------------------------------------------------------------
-- Overview: headline KPIs for the dashboard hero.
-- ---------------------------------------------------------------------------
create or replace function public.ats_report_overview(
  p_company uuid default null, p_from timestamptz default null, p_to timestamptz default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_co uuid; v jsonb;
begin
  v_co := public.ats_report_company(p_company);
  if v_co is null then return '{}'::jsonb; end if;

  select jsonb_build_object(
    'company_id', v_co,
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'open_reqs',       (select count(*) from public.postings po where po.company_id=v_co and po.status='active'),
    'total_reqs',      (select count(*) from public.postings po where po.company_id=v_co),
    'total_candidates',(select count(*) from public.applications a where a.company_id=v_co),
    'active_candidates',(select count(*) from public.applications a where a.company_id=v_co and a.status='active'),
    'hired_total',     (select count(*) from public.applications a where a.company_id=v_co and a.status='hired'),
    'rejected_total',  (select count(*) from public.applications a where a.company_id=v_co and a.status='rejected'),
    'new_candidates',  (select count(*) from public.applications a
                          where a.company_id=v_co
                            and (p_from is null or a.applied_at>=p_from)
                            and (p_to   is null or a.applied_at< p_to)),
    'hires',           (select count(*) from public.application_activities aa
                          where aa.company_id=v_co and aa.type='hired'
                            and (p_from is null or aa.created_at>=p_from)
                            and (p_to   is null or aa.created_at< p_to)),
    'rejects',         (select count(*) from public.application_activities aa
                          where aa.company_id=v_co and aa.type='rejected'
                            and (p_from is null or aa.created_at>=p_from)
                            and (p_to   is null or aa.created_at< p_to)),
    'avg_time_to_hire_days', (
       select round(avg(extract(epoch from (h.hired_at - a.applied_at))/86400)::numeric, 1)
       from public.applications a
       join lateral (select min(aa.created_at) hired_at from public.application_activities aa
                     where aa.application_id=a.id and aa.type='hired') h on true
       where a.company_id=v_co and a.status='hired' and h.hired_at is not null
         and (p_from is null or h.hired_at>=p_from) and (p_to is null or h.hired_at< p_to)),
    'interviews_scheduled', (select count(*) from public.interviews i
                          where i.company_id=v_co
                            and (p_from is null or i.created_at>=p_from)
                            and (p_to   is null or i.created_at< p_to)),
    'interviews_upcoming', (select count(*) from public.interviews i
                          where i.company_id=v_co and i.status='scheduled' and i.scheduled_at>=now()),
    'team_size', (select 1 + (select count(*) from public.company_members cm where cm.company_id=v_co))
  ) into v;
  return v;
end $$;
grant execute on function public.ats_report_overview(uuid, timestamptz, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- Funnel: how many candidates reached each stage category + conversion.
-- "Reached" = any stage_change/created into that category, OR current stage,
-- OR a hired status. Base = applications whose applied_at is in the window.
-- ---------------------------------------------------------------------------
create or replace function public.ats_report_funnel(
  p_company uuid default null, p_from timestamptz default null, p_to timestamptz default null,
  p_posting uuid default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_co uuid; v jsonb;
begin
  v_co := public.ats_report_company(p_company);
  if v_co is null then return '[]'::jsonb; end if;

  with base as (
    select a.id from public.applications a
    where a.company_id=v_co
      and (p_posting is null or a.posting_id=p_posting)
      and (p_from is null or a.applied_at>=p_from) and (p_to is null or a.applied_at< p_to)
  ),
  reached as (
    select aa.application_id app, public.ats_cat_rank(ts.category::text) rank
      from public.application_activities aa join public.job_stages ts on ts.id=aa.to_stage_id
      where aa.company_id=v_co
    union all
    select a.id, public.ats_cat_rank(cs.category::text)
      from public.applications a join public.job_stages cs on cs.id=a.current_stage_id where a.company_id=v_co
    union all
    select a.id, 5 from public.applications a where a.company_id=v_co and a.status='hired'
  ),
  peak as (select b.id, coalesce(max(r.rank),1) max_rank from base b left join reached r on r.app=b.id group by b.id),
  cats as (select * from (values ('applied',1,'Applied'),('screen',2,'Screen'),('interview',3,'Interview'),('offer',4,'Offer'),('hired',5,'Hired')) as t(cat,rank,label)),
  counts as (
    select c.cat, c.rank, c.label,
      (select count(*) from peak p where p.max_rank>=c.rank)::numeric cnt
    from cats c
  ),
  windowed as (
    select cat, rank, label, cnt,
      first_value(cnt) over (order by rank) as top_cnt,
      lag(cnt) over (order by rank) as prev_cnt
    from counts
  )
  select jsonb_agg(jsonb_build_object(
    'category', cat, 'label', label, 'rank', rank, 'count', cnt,
    'pct_of_top',  case when top_cnt>0 then round(cnt*100.0/top_cnt,1) else 0 end,
    'pct_of_prev', case when prev_cnt is null then 100
                        when prev_cnt>0 then round(cnt*100.0/prev_cnt,1) else 0 end
  ) order by rank) into v from windowed;

  return coalesce(v,'[]'::jsonb);
end $$;
grant execute on function public.ats_report_funnel(uuid, timestamptz, timestamptz, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Velocity: time-to-hire distribution + average dwell in each stage category.
-- ---------------------------------------------------------------------------
create or replace function public.ats_report_velocity(
  p_company uuid default null, p_from timestamptz default null, p_to timestamptz default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_co uuid; v_tth jsonb; v_dwell jsonb;
begin
  v_co := public.ats_report_company(p_company);
  if v_co is null then return '{}'::jsonb; end if;

  select jsonb_build_object(
    'count', count(*),
    'avg_days', round(avg(d)::numeric,1),
    'fastest_days', round(min(d)::numeric,1),
    'slowest_days', round(max(d)::numeric,1)
  ) into v_tth
  from (
    select extract(epoch from (h.hired_at - a.applied_at))/86400 d
    from public.applications a
    join lateral (select min(aa.created_at) hired_at from public.application_activities aa
                  where aa.application_id=a.id and aa.type='hired') h on true
    where a.company_id=v_co and a.status='hired' and h.hired_at is not null
      and (p_from is null or h.hired_at>=p_from) and (p_to is null or h.hired_at< p_to)
  ) x;

  with sc as (
    select aa.application_id app, ts.category::text cat, aa.created_at,
      lead(aa.created_at) over (partition by aa.application_id order by aa.created_at) next_at
    from public.application_activities aa
    join public.job_stages ts on ts.id=aa.to_stage_id
    where aa.company_id=v_co and aa.type in ('created','stage_change')
  ),
  dwell as (
    select cat, public.ats_cat_rank(cat) rnk,
      round(avg(extract(epoch from (coalesce(next_at, now()) - created_at))/86400)::numeric,1) avg_days,
      count(*) n
    from sc group by cat
  )
  select jsonb_agg(jsonb_build_object('category', cat, 'label', initcap(cat),
           'avg_days', avg_days, 'n', n) order by rnk)
  into v_dwell
  from dwell;

  return jsonb_build_object('time_to_hire', coalesce(v_tth,'{}'::jsonb), 'stage_dwell', coalesce(v_dwell,'[]'::jsonb));
end $$;
grant execute on function public.ats_report_velocity(uuid, timestamptz, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- Sources: where candidates come from and how well each converts.
-- ---------------------------------------------------------------------------
create or replace function public.ats_report_sources(
  p_company uuid default null, p_from timestamptz default null, p_to timestamptz default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_co uuid; v jsonb;
begin
  v_co := public.ats_report_company(p_company);
  if v_co is null then return '[]'::jsonb; end if;

  select jsonb_agg(jsonb_build_object(
    'source', source, 'total', total, 'active', active, 'hired', hired, 'rejected', rejected,
    'hire_rate', case when total>0 then round(hired*100.0/total,1) else 0 end
  ) order by total desc) into v
  from (
    select a.source::text source,
      count(*) total,
      count(*) filter (where a.status='active') active,
      count(*) filter (where a.status='hired') hired,
      count(*) filter (where a.status='rejected') rejected
    from public.applications a
    where a.company_id=v_co
      and (p_from is null or a.applied_at>=p_from) and (p_to is null or a.applied_at< p_to)
    group by a.source
  ) x;
  return coalesce(v,'[]'::jsonb);
end $$;
grant execute on function public.ats_report_sources(uuid, timestamptz, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- Recruiter productivity: activity per team member in the window.
-- ---------------------------------------------------------------------------
create or replace function public.ats_report_recruiters(
  p_company uuid default null, p_from timestamptz default null, p_to timestamptz default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_co uuid; v jsonb;
begin
  v_co := public.ats_report_company(p_company);
  if v_co is null then return '[]'::jsonb; end if;

  with people as (
    select owner_id pid, 'admin'::text role from public.companies where id=v_co
    union
    select cm.profile_id, cm.member_role from public.company_members cm where cm.company_id=v_co
  ),
  act as (
    select aa.actor_id pid,
      count(*) filter (where aa.type='stage_change') moves,
      count(*) filter (where aa.type='note') notes,
      count(*) filter (where aa.type='hired') hires
    from public.application_activities aa
    where aa.company_id=v_co
      and (p_from is null or aa.created_at>=p_from) and (p_to is null or aa.created_at< p_to)
    group by aa.actor_id
  ),
  sc as (
    select interviewer_id pid, count(*) c from public.scorecards
    where company_id=v_co and (p_from is null or created_at>=p_from) and (p_to is null or created_at< p_to)
    group by interviewer_id
  ),
  iv as (
    select created_by pid, count(*) c from public.interviews
    where company_id=v_co and (p_from is null or created_at>=p_from) and (p_to is null or created_at< p_to)
    group by created_by
  )
  select jsonb_agg(jsonb_build_object(
    'name', coalesce(nullif(pr.full_name,''),'—'), 'role', p.role,
    'moves', coalesce(act.moves,0), 'notes', coalesce(act.notes,0),
    'scorecards', coalesce(sc.c,0), 'interviews', coalesce(iv.c,0), 'hires', coalesce(act.hires,0)
  ) order by (coalesce(act.moves,0)+coalesce(act.notes,0)+coalesce(sc.c,0)+coalesce(iv.c,0)) desc)
  into v
  from people p
  join public.profiles pr on pr.id=p.pid
  left join act on act.pid=p.pid
  left join sc on sc.pid=p.pid
  left join iv on iv.pid=p.pid;
  return coalesce(v,'[]'::jsonb);
end $$;
grant execute on function public.ats_report_recruiters(uuid, timestamptz, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- Requisitions: status of every open/closed job.
-- ---------------------------------------------------------------------------
create or replace function public.ats_report_jobs(
  p_company uuid default null, p_from timestamptz default null, p_to timestamptz default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_co uuid; v jsonb;
begin
  v_co := public.ats_report_company(p_company);
  if v_co is null then return '[]'::jsonb; end if;

  select jsonb_agg(jsonb_build_object(
    'id', po.id, 'title', po.title, 'department', po.department, 'status', po.status,
    'candidates', (select count(*) from public.applications a where a.posting_id=po.id),
    'active',     (select count(*) from public.applications a where a.posting_id=po.id and a.status='active'),
    'hired',      (select count(*) from public.applications a where a.posting_id=po.id and a.status='hired'),
    'reached_interview', (
        select count(distinct a.id) from public.applications a
        where a.posting_id=po.id and (
          a.status='hired'
          or exists (select 1 from public.job_stages cs where cs.id=a.current_stage_id and public.ats_cat_rank(cs.category::text)>=3)
          or exists (select 1 from public.application_activities aa join public.job_stages ts on ts.id=aa.to_stage_id
                     where aa.application_id=a.id and public.ats_cat_rank(ts.category::text)>=3))),
    'days_open', round(extract(epoch from (now()-po.created_at))/86400)
  ) order by po.created_at desc) into v
  from public.postings po where po.company_id=v_co;
  return coalesce(v,'[]'::jsonb);
end $$;
grant execute on function public.ats_report_jobs(uuid, timestamptz, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- Diversity: admin-only aggregate EEO across the company's postings, with
-- small-cell suppression (min 5). Reuses the eeo_responses firewall — recruiters
-- still cannot read individual rows; this only ever returns grouped counts.
-- ---------------------------------------------------------------------------
create or replace function public.ats_report_diversity(
  p_company uuid default null, p_min_cell int default 5)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_co uuid; v jsonb;
begin
  v_co := public.ats_report_company(p_company);
  if v_co is null or not public.is_company_admin(v_co) then return '{}'::jsonb; end if;

  select jsonb_object_agg(category, vals) into v
  from (
    select category, jsonb_agg(jsonb_build_object('value', value, 'n', n) order by n desc) vals
    from (
      select e.category, e.value, count(*) n
      from public.eeo_responses e
      join public.postings po on po.id=e.posting_id
      where po.company_id=v_co
      group by e.category, e.value
      having count(*) >= greatest(p_min_cell,1)
    ) c
    group by category
  ) g;
  return jsonb_build_object('min_cell', greatest(p_min_cell,1), 'categories', coalesce(v,'{}'::jsonb));
end $$;
grant execute on function public.ats_report_diversity(uuid, int) to authenticated;
