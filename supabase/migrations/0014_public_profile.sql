-- ============================================================================
-- GigCute — public_profile RPC
-- Returns a seeker's shareable profile (name + headline + photo + resume +
-- linkedin + work history + favorited prompt answers) by id, as one JSON object,
-- for the public /profile/<id> page. security definer so the (otherwise
-- self/admin-only) display name can be shown; gated on the profile being visible.
-- Includes the resume_url column add so this file is self-contained.
-- ============================================================================
alter table public.seeker_profiles add column if not exists resume_url text;

create or replace function public.public_profile(p_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select case
    when not exists (
      select 1 from public.seeker_profiles sp
      where sp.profile_id = p_id and sp.is_visible
    ) then null
    else jsonb_build_object(
      'id',           p_id,
      'name',         (select full_name from public.profiles where id = p_id),
      'headline',     sp.headline,
      'photo_url',    sp.photo_url,
      'resume_url',   sp.resume_url,
      'linkedin_url', sp.linkedin_url,
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

grant execute on function public.public_profile(uuid) to anon, authenticated;
