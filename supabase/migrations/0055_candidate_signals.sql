-- ============================================================================
-- GigCute — candidate_signals: recruiter-facing badges for a batch of seekers
--   in_demand   = # of distinct companies that have shown recruiter interest
--   last_active = most recent of (their latest posting-like, profile update)
-- Aggregate only — no identities of the interested companies are exposed.
-- ============================================================================
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
  from unnest(coalesce(p_seekers, '{}'::uuid[])) as s(sid);
$$;

grant execute on function public.candidate_signals(uuid[]) to authenticated;
