-- ============================================================================
-- GigCute — expose skills on the public profile
-- seeker_profiles.skills (text[]) is now captured in the profile form/resume
-- parser and used by job matching, but public_profile() didn't return it, so it
-- never showed on the profile page. Add it (as a JSON array). public_profile_by_code
-- delegates to public_profile, so it inherits the field automatically.
-- ============================================================================
create or replace function public.public_profile(p_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select case
    when not exists (
      select 1 from public.seeker_profiles sp
      where sp.profile_id = p_id and sp.is_visible
    ) then null
    else jsonb_build_object(
      'id',           p_id,
      'code',         sp.public_code,
      'name',         (select full_name from public.profiles where id = p_id),
      'headline',     sp.headline,
      'photo_url',    sp.photo_url,
      'resume_url',   sp.resume_url,
      'linkedin_url', sp.linkedin_url,
      'skills',       coalesce(to_jsonb(sp.skills), '[]'::jsonb),
      'portfolio',    coalesce(sp.portfolio, '[]'::jsonb),
      'certifications', coalesce(sp.certifications, '[]'::jsonb),
      'work', coalesce((
        select jsonb_agg(jsonb_build_object(
          'title', w.title, 'company', w.company,
          'start', w.start_label, 'end', w.end_label, 'description', w.description
        ) order by w.sort_order)
        from public.work_history w where w.seeker_id = p_id), '[]'::jsonb),
      'education', coalesce((
        select jsonb_agg(jsonb_build_object('degree', e.degree, 'school', e.school, 'year', e.year) order by e.sort_order)
        from public.education e where e.seeker_id = p_id), '[]'::jsonb),
      'prompts', coalesce((
        select jsonb_agg(jsonb_build_object('label', a.prompt_label, 'answer', a.answer) order by a.sort_order)
        from public.seeker_prompt_answers a where a.seeker_id = p_id and a.is_favorite), '[]'::jsonb)
    )
  end
  from public.seeker_profiles sp where sp.profile_id = p_id;
$$;

grant execute on function public.public_profile(uuid) to anon, authenticated;
