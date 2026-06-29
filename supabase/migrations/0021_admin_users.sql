-- ============================================================================
-- GigCute — admin user directory
-- Admin-only RPC to list/search registered users (auth + profile + seeker row).
-- Returns { total, users: [...] }; null for non-admins.
-- ============================================================================
create or replace function public.admin_users(p_search text default null, p_limit int default 200)
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare result jsonb; q text;
begin
  if not public.is_admin() then return null; end if;
  q := nullif(trim(coalesce(p_search, '')), '');

  select jsonb_build_object(
    'total', (select count(*) from auth.users),
    'users', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',        u.id,
        'email',     u.email,
        'name',      p.full_name,
        'role',      p.role,
        'code',      sp.public_code,
        'headline',  sp.headline,
        'visible',   sp.is_visible,
        'confirmed', (u.email_confirmed_at is not null),
        'created_at', u.created_at
      ) order by u.created_at desc)
      from auth.users u
      left join public.profiles p        on p.id = u.id
      left join public.seeker_profiles sp on sp.profile_id = u.id
      where q is null
         or u.email ilike '%'||q||'%'
         or p.full_name ilike '%'||q||'%'
         or sp.public_code ilike '%'||q||'%'
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

grant execute on function public.admin_users(text, int) to authenticated;
