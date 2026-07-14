-- ============================================================================
-- GigCute — security hardening (audit follow-ups).
-- 1. The 0004 "verified recruiter" firewall now also applies to the owner-gated
--    RPCs that expose candidate data: an unverified company could previously
--    post a job and harvest the candidate pool through recommend_candidates /
--    seekers_who_liked / posting_stats / posting_audience.
-- 2. candidate_signals had NO access check at all — now verified recruiters only.
-- 3. Messages are immutable once sent: the read-receipt UPDATE policy allowed a
--    participant to rewrite the other party's message body. A trigger now
--    permits only read_at changes.
-- 4. anon loses direct INSERT/UPDATE/DELETE on tables (RLS already blocked it;
--    this removes the belt-and-suspenders gap for future tables too). Visitor
--    analytics keeps its events INSERT.
-- NOTE: NGU Business Real Estate is marked verified first so the platform
-- owner's live recruiter flows are unaffected by the new gates.
-- ============================================================================

-- 0. Verify the owner's real company before the gates land.
update public.companies set verified = true where name ilike 'NGU Business Real Estate%';

-- 1a. seekers_who_liked — owner AND verified.
create or replace function public.seekers_who_liked(p_posting uuid)
returns table(seeker_id uuid, full_name text, headline text, photo_url text, mutual boolean)
language sql stable security definer set search_path = public as $$
  select p.id, p.full_name, sp.headline, sp.photo_url,
         exists(select 1 from public.recruiter_interest ri
                 where ri.posting_id = p_posting and ri.seeker_id = p.id) as mutual
  from public.seeker_interest si
  join public.profiles p on p.id = si.seeker_id
  left join public.seeker_profiles sp on sp.profile_id = si.seeker_id
  where si.posting_id = p_posting
    and public.owns_posting(p_posting)
    and public.is_verified_recruiter()
  order by si.created_at desc;
$$;

-- 1b. recommend_candidates — owner AND verified.
create or replace function public.recommend_candidates(p_posting uuid, p_limit int default 8)
returns table(seeker_id uuid, name text, headline text, photo_url text, work_setup text, exp_years int, skills text[], score int)
language sql stable security definer set search_path = public as $$
  with post as (
    select lower(coalesce(p.title,'') || ' ' ||
                 array_to_string(coalesce(p.responsibilities,'{}'::text[]),' ') || ' ' ||
                 array_to_string(coalesce(p.qualifications,'{}'::text[]),' ') || ' ' ||
                 coalesce(p.seniority,'')) as txt
    from public.postings p where p.id = p_posting
  )
  select sp.profile_id, pr.full_name, sp.headline, sp.photo_url, sp.work_setup, sp.exp_years, sp.skills,
    (select count(*)::int from unnest(coalesce(sp.skills, '{}'::text[])) s
      where (select txt from post) like '%' || lower(s) || '%') as score
  from public.seeker_profiles sp
  join public.profiles pr on pr.id = sp.profile_id
  where public.owns_posting(p_posting)
    and public.is_verified_recruiter()
    and sp.is_visible
    and sp.profile_id not in (select seeker_id from public.seeker_interest where posting_id = p_posting)
    and sp.profile_id not in (select seeker_id from public.posting_dismissed where posting_id = p_posting)
  order by score desc, sp.updated_at desc nulls last
  limit greatest(1, least(coalesce(p_limit, 8), 24));
$$;

-- 1c. posting_stats — owner AND verified.
create or replace function public.posting_stats(p_posting uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not (public.owns_posting(p_posting) and public.is_verified_recruiter()) then null else jsonb_build_object(
    'views',      (select count(distinct viewer_key) from public.posting_views where posting_id = p_posting),
    'views_7d',   (select count(distinct viewer_key) from public.posting_views where posting_id = p_posting and viewed_at >= now() - interval '7 days'),
    'interested', (select count(*) from public.seeker_interest where posting_id = p_posting)
  ) end;
$$;

-- 1d. posting_audience — owner AND verified.
create or replace function public.posting_audience(p_posting uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with g as (
    select
      exists(select 1 from public.seeker_interest si where si.posting_id = p_posting and si.seeker_id = v.viewer_id) as liked,
      coalesce(nullif(btrim(sp.work_setup), ''), 'Unspecified') as ws,
      case when sp.exp_years is null then 'Unknown'
           when sp.exp_years < 2 then '0-2 yrs'
           when sp.exp_years < 5 then '2-5 yrs'
           when sp.exp_years < 10 then '5-10 yrs'
           else '10+ yrs' end as exp
    from (select distinct viewer_id from public.posting_views where posting_id = p_posting and viewer_id is not null) v
    join public.seeker_profiles sp on sp.profile_id = v.viewer_id
    where public.owns_posting(p_posting) and public.is_verified_recruiter()
  )
  select jsonb_build_object(
    'liked_count', count(*) filter (where liked),
    'other_count', count(*) filter (where not liked),
    'work_setup', jsonb_build_object(
      'liked', (select coalesce(jsonb_object_agg(ws, c), '{}') from (select ws, count(*) c from g where liked group by ws) t),
      'other', (select coalesce(jsonb_object_agg(ws, c), '{}') from (select ws, count(*) c from g where not liked group by ws) t)),
    'experience', jsonb_build_object(
      'liked', (select coalesce(jsonb_object_agg(exp, c), '{}') from (select exp, count(*) c from g where liked group by exp) t),
      'other', (select coalesce(jsonb_object_agg(exp, c), '{}') from (select exp, count(*) c from g where not liked group by exp) t))
  ) from g;
$$;

-- 2. candidate_signals — was completely ungated; now verified recruiters only.
create or replace function public.candidate_signals(p_seekers uuid[])
returns table(seeker_id uuid, in_demand int, last_active timestamptz)
language sql stable security definer set search_path = public as $$
  select s.sid,
    (select count(distinct p.company_id)::int
       from public.recruiter_interest ri
       join public.postings p on p.id = ri.posting_id
       where ri.seeker_id = s.sid),
    greatest(
      (select max(created_at) from public.seeker_interest where seeker_id = s.sid),
      (select updated_at from public.seeker_profiles where profile_id = s.sid)
    )
  from unnest(coalesce(p_seekers, '{}'::uuid[])) as s(sid)
  where public.is_verified_recruiter();
$$;
revoke execute on function public.candidate_signals(uuid[]) from anon;

-- 3. Messages are immutable — the UPDATE policy exists only for read receipts.
create or replace function public.enforce_read_receipt_only()
returns trigger language plpgsql as $$
begin
  if NEW.body is distinct from OLD.body
     or NEW.sender_id is distinct from OLD.sender_id
     or NEW.conversation_id is distinct from OLD.conversation_id
     or NEW.created_at is distinct from OLD.created_at then
    raise exception 'Messages cannot be edited.' using errcode = 'GC060';
  end if;
  return NEW;
end $$;
drop trigger if exists trg_read_receipt_only on public.messages;
create trigger trg_read_receipt_only before update on public.messages
  for each row execute function public.enforce_read_receipt_only();

-- 4. anon keeps reads (RLS-guarded) + events INSERT (visitor analytics), loses
--    every other write — including on FUTURE tables via default privileges.
revoke insert, update, delete on all tables in schema public from anon;
grant insert on public.events to anon;
alter default privileges in schema public revoke insert, update, delete on tables from anon;
