-- ============================================================================
-- GigCute — short shareable profile codes
-- Replaces the long UUID in /profile/<id> URLs with a stable 6-char code, e.g.
-- gigcute.com/profile/k7m4p2. The code is stored on seeker_profiles, generated
-- on insert, backfilled for existing rows, and resolved by a public RPC.
-- ============================================================================
alter table public.seeker_profiles add column if not exists public_code text;

-- 6-char code from an unambiguous lowercase alphanumeric alphabet (no l/o/0/1).
create or replace function public.gen_profile_code() returns text
language plpgsql as $$
declare
  alphabet text := 'abcdefghijkmnpqrstuvwxyz23456789';
  code text;
  i int;
begin
  loop
    code := '';
    for i in 1..6 loop
      code := code || substr(alphabet, floor(random() * length(alphabet))::int + 1, 1);
    end loop;
    exit when not exists (select 1 from public.seeker_profiles where public_code = code);
  end loop;
  return code;
end;
$$;

-- Assign a code on insert when one isn't provided.
create or replace function public.set_profile_code() returns trigger
language plpgsql as $$
begin
  if new.public_code is null then new.public_code := public.gen_profile_code(); end if;
  return new;
end;
$$;

drop trigger if exists trg_set_profile_code on public.seeker_profiles;
create trigger trg_set_profile_code before insert on public.seeker_profiles
  for each row execute function public.set_profile_code();

-- Backfill existing profiles.
update public.seeker_profiles set public_code = public.gen_profile_code() where public_code is null;

create unique index if not exists seeker_profiles_public_code_key on public.seeker_profiles(public_code);

-- public_profile now also returns the short code.
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

-- Resolve a profile by its short code (returns the same JSON shape).
create or replace function public.public_profile_by_code(p_code text)
returns jsonb language sql stable security definer set search_path = public as $$
  select public.public_profile(sp.profile_id)
  from public.seeker_profiles sp
  where sp.public_code = p_code and sp.is_visible
  limit 1;
$$;

grant execute on function public.public_profile(uuid) to anon, authenticated;
grant execute on function public.public_profile_by_code(text) to anon, authenticated;
