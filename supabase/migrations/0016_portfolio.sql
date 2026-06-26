-- ============================================================================
-- GigCute — Portfolio & Projects
-- A seeker can list bodies of work (projects, case studies, demos, galleries).
-- Each item links OUT to where the work lives (an external site / video / image)
-- and is described here. Stored as a JSON array on the seeker_profiles row
-- (display-only, never queried), so no separate table is needed.
-- Item shape: { "title": text, "url": text, "description": text }
-- ============================================================================
alter table public.seeker_profiles add column if not exists portfolio jsonb not null default '[]'::jsonb;

-- Surface portfolio in the public profile payload.
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
      'portfolio',    coalesce(sp.portfolio, '[]'::jsonb),
      'work', coalesce((
        select jsonb_agg(jsonb_build_object(
          'title', w.title, 'company', w.company,
          'start', w.start_label, 'end', w.end_label, 'description', w.description
        ) order by w.sort_order)
        from public.work_history w where w.seeker_id = p_id), '[]'::jsonb),
      'prompts', coalesce((
        select jsonb_agg(jsonb_build_object('label', a.prompt_label, 'answer', a.answer) order by a.sort_order)
        from public.seeker_prompt_answers a where a.seeker_id = p_id and a.is_favorite), '[]'::jsonb)
    )
  end
  from public.seeker_profiles sp where sp.profile_id = p_id;
$$;

-- by_code delegates to public_profile, so it inherits the new field automatically.
grant execute on function public.public_profile(uuid) to anon, authenticated;
