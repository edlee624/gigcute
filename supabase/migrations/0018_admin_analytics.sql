-- ============================================================================
-- GigCute — admin analytics
-- Flags the owner account as admin and adds a security-definer RPC that returns
-- aggregated visit/event analytics ONLY to admins. The events table stays
-- admin-read-only (RLS), so non-admins/anonymous users can't read raw events.
-- ============================================================================

-- 1) Make the owner an admin (HYUN HO / edios624@gmail.com).
update public.profiles set role = 'admin'
where id = '8dc8630a-0850-4a94-b11d-437b54e76ab5';

-- 2) Aggregated analytics, gated to admins.
create or replace function public.admin_analytics()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare result jsonb;
begin
  if not public.is_admin() then
    return null;  -- not an admin: reveal nothing
  end if;

  select jsonb_build_object(
    'total',         (select count(*) from public.events),
    'screen_views',  (select count(*) from public.events where type = 'screen_view'),
    'profile_views', (select count(*) from public.events where type = 'profile_viewed'),
    'unique_users',  (select count(distinct user_id) from public.events where user_id is not null),
    'last_7d',       (select count(*) from public.events where created_at > now() - interval '7 days'),
    'by_type', coalesce((
      select jsonb_agg(jsonb_build_object('type', type, 'count', c) order by c desc)
      from (select type, count(*) c from public.events group by type) t), '[]'::jsonb),
    'top_screens', coalesce((
      select jsonb_agg(jsonb_build_object('screen', screen, 'count', c) order by c desc)
      from (select coalesce(data->>'screen','(unknown)') as screen, count(*) c
            from public.events where type = 'screen_view'
            group by 1 order by count(*) desc limit 12) s), '[]'::jsonb),
    'by_day', coalesce((
      select jsonb_agg(jsonb_build_object('day', day, 'count', c) order by day)
      from (select to_char(date_trunc('day', created_at), 'YYYY-MM-DD') as day, count(*) c
            from public.events where created_at > now() - interval '30 days'
            group by 1) d), '[]'::jsonb),
    'recent', coalesce((
      select jsonb_agg(jsonb_build_object('created_at', created_at, 'type', type, 'data', data) order by created_at desc)
      from (select created_at, type, data from public.events order by created_at desc limit 50) r), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

grant execute on function public.admin_analytics() to authenticated;
