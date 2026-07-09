-- ============================================================================
-- GigCute — recruiter can dismiss a recommended candidate for a posting.
-- Dismissed candidates drop out of recommend_candidates so the next-best moves
-- up. Owner-gated; persists per posting.
-- ============================================================================
create table if not exists public.posting_dismissed (
  posting_id uuid not null references public.postings(id) on delete cascade,
  seeker_id  uuid not null references public.seeker_profiles(profile_id) on delete cascade,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (posting_id, seeker_id)
);
alter table public.posting_dismissed enable row level security;
drop policy if exists "posting_dismissed: owner all" on public.posting_dismissed;
create policy "posting_dismissed: owner all" on public.posting_dismissed for all
  using (public.owns_posting(posting_id)) with check (public.owns_posting(posting_id));

create or replace function public.dismiss_candidate(p_posting uuid, p_seeker uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.owns_posting(p_posting) then return; end if;
  insert into public.posting_dismissed (posting_id, seeker_id, created_by)
  values (p_posting, p_seeker, auth.uid())
  on conflict (posting_id, seeker_id) do nothing;
  -- removing a candidate also withdraws any invite to them for this posting
  delete from public.invites where posting_id = p_posting and seeker_id = p_seeker;
end $$;
grant execute on function public.dismiss_candidate(uuid, uuid) to authenticated;

-- Recommendations now also exclude dismissed candidates.
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
    and sp.profile_id not in (select seeker_id from public.posting_dismissed where posting_id = p_posting)
  order by score desc, sp.updated_at desc nulls last
  limit greatest(1, least(coalesce(p_limit, 8), 24));
$$;
grant execute on function public.recommend_candidates(uuid, int) to authenticated;
