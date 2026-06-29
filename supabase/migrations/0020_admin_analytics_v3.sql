-- ============================================================================
-- GigCute — admin analytics v3
-- Adds unique visitors (by a persistent client visitor id), signups (a new
-- 'signup' event), and top referrers (from the captured referrer URL).
-- ============================================================================
create or replace function public.admin_analytics(p_days int default null)
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare result jsonb; since timestamptz;
begin
  if not public.is_admin() then return null; end if;
  since := case when p_days is null then '-infinity'::timestamptz
                else now() - (p_days || ' days')::interval end;

  select jsonb_build_object(
    'days', p_days,
    'total',           (select count(*) from public.events where created_at >= since),
    'screen_views',    (select count(*) from public.events where type='screen_view' and created_at >= since),
    'profile_views',   (select count(*) from public.events where type='profile_viewed' and created_at >= since),
    'unique_users',    (select count(distinct user_id) from public.events where user_id is not null and created_at >= since),
    'unique_visitors', (select count(distinct data->>'vid') from public.events where data ? 'vid' and data->>'vid' <> '' and created_at >= since),
    'signups',         (select count(*) from public.events where type='signup' and created_at >= since),
    'last_7d',         (select count(*) from public.events where created_at > now() - interval '7 days'),
    'by_type', coalesce((select jsonb_agg(jsonb_build_object('type',type,'count',c) order by c desc)
      from (select type, count(*) c from public.events where created_at >= since group by type) t), '[]'::jsonb),
    'top_screens', coalesce((select jsonb_agg(jsonb_build_object('screen',screen,'count',c) order by c desc)
      from (select coalesce(data->>'screen','(unknown)') as screen, count(*) c from public.events
            where type='screen_view' and created_at >= since group by 1 order by count(*) desc limit 12) s), '[]'::jsonb),
    'top_referrers', coalesce((select jsonb_agg(jsonb_build_object('ref',ref,'count',c) order by c desc)
      from (select case
                     when coalesce(data->>'ref','') = '' then 'Direct / none'
                     else coalesce(nullif(regexp_replace(data->>'ref', '^https?://([^/]+).*$', '\1'), ''), data->>'ref')
                   end as ref,
                   count(distinct coalesce(data->>'vid', id::text)) c
            from public.events
            where type='screen_view' and created_at >= since
            group by 1 order by 2 desc limit 12) rf), '[]'::jsonb),
    'by_day', coalesce((select jsonb_agg(jsonb_build_object('day', d.day, 'count', d.c) order by d.day)
      from (select to_char(date_trunc('day',created_at),'YYYY-MM-DD') as day, count(*) as c from public.events
            where created_at > now() - (coalesce(p_days,30) || ' days')::interval group by 1) d), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(jsonb_build_object(
        'created_at', e.created_at, 'type', e.type,
        'detail', coalesce(e.data->>'screen', case when e.data ? 'shared' then (case when (e.data->>'shared')::boolean then 'shared link' else 'own' end) else '' end),
        'account', (select u.email from auth.users u where u.id = e.user_id),
        'ip', e.data->>'ip', 'city', e.data->>'city', 'country', e.data->>'country', 'ua', e.data->>'ua'
      ) order by e.created_at desc)
      from (select * from public.events where created_at >= since order by created_at desc limit 100) e), '[]'::jsonb)
  ) into result;
  return result;
end; $$;

grant execute on function public.admin_analytics(int) to authenticated;
