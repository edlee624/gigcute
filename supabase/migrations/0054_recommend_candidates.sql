-- ============================================================================
-- GigCute — recommend_candidates: potential-match suggestions for a posting
-- Ranks VISIBLE seekers (who haven't already expressed interest) by how many of
-- their skills appear in the posting's text (title + responsibilities +
-- qualifications + seniority). Owner-gated; returns safe fields for display.
-- ============================================================================
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
    and sp.is_visible
    and sp.profile_id not in (select seeker_id from public.seeker_interest where posting_id = p_posting)
  order by score desc, sp.updated_at desc nulls last
  limit greatest(1, least(coalesce(p_limit, 8), 24));
$$;

grant execute on function public.recommend_candidates(uuid, int) to authenticated;
