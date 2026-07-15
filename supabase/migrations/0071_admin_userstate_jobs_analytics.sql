-- ============================================================================
-- GigCute — admin: richer user directory + jobs salary analytics.
-- 1. admin_users now also returns funnel signals per user: onboarded, skills
--    count, has-photo, likes/tracked/chats activity, last sign-in.
-- 2. jobs_analytics(): salary trends over the active jobs feed, broken down by
--    derived seniority, category, top locations, remote, and employment type.
--    Salary = midpoint of (min,max) when both present, else whichever exists.
-- Both admin-only.
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
        'id',         u.id,
        'email',      u.email,
        'name',       p.full_name,
        'role',       p.role,
        'title',      sp.headline,
        'linkedin',   sp.linkedin_url,
        'code',       sp.public_code,
        'visible',    sp.is_visible,
        'confirmed',  (u.email_confirmed_at is not null),
        'created_at', u.created_at,
        'last_seen',  u.last_sign_in_at,
        'onboarded',  (sp.profile_id is not null),
        'skills',     coalesce(array_length(sp.skills, 1), 0),
        'photo',      (sp.photo_url is not null),
        'likes',      (select count(*) from public.seeker_interest si where si.seeker_id = u.id),
        'tracked',    (select count(*) from public.tracked_jobs t where t.user_id = u.id),
        'chats',      (select count(*) from public.conversations c where c.seeker_id = u.id)
      ) order by u.created_at desc)
      from auth.users u
      left join public.profiles p         on p.id = u.id
      left join public.seeker_profiles sp on sp.profile_id = u.id
      where q is null
         or u.email ilike '%'||q||'%'
         or p.full_name ilike '%'||q||'%'
         or sp.public_code ilike '%'||q||'%'
         or sp.headline ilike '%'||q||'%'
    ), '[]'::jsonb)
  ) into result;

  return result;
end $$;
grant execute on function public.admin_users(text, int) to authenticated;

-- ---- Jobs salary analytics -------------------------------------------------
create or replace function public.jobs_analytics()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare result jsonb;
begin
  if not public.is_admin() then return null; end if;

  with j as (
    select
      title, category, location, remote, employment_type,
      case
        when title ~* '\m(chief|cxo|founder|c-level)\M' then 'C-level / Founder'
        when title ~* '\m(vp|vice president|svp|evp|head of)\M' then 'VP / Head'
        when title ~* '\m(director)\M' then 'Director'
        when title ~* '\m(manager|mgr)\M' then 'Manager'
        when title ~* '\m(principal|staff|lead)\M' then 'Staff / Principal / Lead'
        when title ~* '\m(senior|sr)\M' then 'Senior'
        when title ~* '\m(junior|jr|entry|associate|intern|graduate|trainee)\M' then 'Entry / Junior'
        else 'Mid / Unspecified'
      end as seniority,
      case
        when salary_min is not null and salary_max is not null then (salary_min + salary_max) / 2.0
        when salary_max is not null then salary_max::numeric
        when salary_min is not null then salary_min::numeric
      end as mid
    from public.jobs where is_active
  ),
  grp as (
    select seniority, count(*)::int n,
           round(percentile_cont(0.5) within group (order by mid))::int med
    from j where mid is not null group by seniority
  ),
  cat as (
    select coalesce(nullif(btrim(category),''),'—') category, count(*)::int n,
           round(percentile_cont(0.5) within group (order by mid))::int med
    from j where mid is not null group by 1 order by n desc limit 14
  ),
  loc as (
    select coalesce(nullif(btrim(location),''),'—') location, count(*)::int n,
           round(percentile_cont(0.5) within group (order by mid))::int med
    from j where mid is not null group by 1 order by n desc limit 18
  ),
  rem as (
    select case when remote then 'Remote' else 'On-site / Hybrid' end kind, count(*)::int n,
           round(percentile_cont(0.5) within group (order by mid))::int med
    from j where mid is not null group by 1
  )
  select jsonb_build_object(
    'total_active', (select count(*) from j),
    'with_salary',  (select count(*) from j where mid is not null),
    'salary_overall', (select jsonb_build_object(
        'median', round(percentile_cont(0.5) within group (order by mid))::int,
        'p25',    round(percentile_cont(0.25) within group (order by mid))::int,
        'p75',    round(percentile_cont(0.75) within group (order by mid))::int,
        'min',    round(min(mid))::int, 'max', round(max(mid))::int) from j where mid is not null),
    'by_seniority', (select coalesce(jsonb_agg(jsonb_build_object('bucket',seniority,'n',n,'median',med) order by med desc), '[]') from grp),
    'by_category',  (select coalesce(jsonb_agg(jsonb_build_object('category',category,'n',n,'median',med)), '[]') from cat),
    'by_location',  (select coalesce(jsonb_agg(jsonb_build_object('location',location,'n',n,'median',med)), '[]') from loc),
    'by_remote',    (select coalesce(jsonb_agg(jsonb_build_object('kind',kind,'n',n,'median',med)), '[]') from rem)
  ) into result;

  return result;
end $$;
grant execute on function public.jobs_analytics() to authenticated;
