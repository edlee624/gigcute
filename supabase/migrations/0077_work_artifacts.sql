-- ============================================================================
-- GigCute — work artifacts: projects/presentations attached to a work-history
-- entry. Each artifact is { title, kind:'link'|'file', url, fileName }. Files
-- are uploaded to the public `media` bucket; links are stored as-is. Stored as
-- a jsonb array on the work_history row (work_history is saved wholesale, so the
-- artifacts travel with each entry — no separate table / FK to keep in sync).
-- public_profile() is recreated to expose artifacts so viewers can open links
-- and download files.
-- ============================================================================
alter table public.work_history
  add column if not exists artifacts jsonb not null default '[]';

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
          'start', w.start_label, 'end', w.end_label, 'description', w.description,
          'artifacts', coalesce(w.artifacts, '[]'::jsonb)
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
