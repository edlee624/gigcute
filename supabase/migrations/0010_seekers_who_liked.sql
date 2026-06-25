-- ============================================================================
-- GigCute — seekers_who_liked RPC
-- Lets a posting's owner see the real seekers who expressed interest in it,
-- returning SAFE fields only (display name, headline, photo) — never email.
-- Profile names live in public.profiles (self/admin-only RLS), so this runs as
-- security definer and gates access manually via owns_posting(). `mutual` flags
-- whether the recruiter already liked back (i.e. a match exists).
-- ============================================================================
create or replace function public.seekers_who_liked(p_posting uuid)
returns table(seeker_id uuid, full_name text, headline text, photo_url text, mutual boolean)
language sql stable security definer set search_path = public as $$
  select p.id,
         p.full_name,
         sp.headline,
         sp.photo_url,
         exists(
           select 1 from public.recruiter_interest ri
           where ri.posting_id = p_posting and ri.seeker_id = p.id
         ) as mutual
  from public.seeker_interest si
  join public.profiles p on p.id = si.seeker_id
  left join public.seeker_profiles sp on sp.profile_id = si.seeker_id
  where si.posting_id = p_posting
    and public.owns_posting(p_posting)   -- caller must own the posting; else no rows
  order by si.created_at desc;
$$;

grant execute on function public.seekers_who_liked(uuid) to authenticated;
