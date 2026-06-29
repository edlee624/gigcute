-- ============================================================================
-- GigCute — admin analytics v4: explicit date-range filtering
-- Adds optional p_from / p_to bounds so the admin panel can filter by an exact
-- calendar range, in addition to the existing "last N days" preset. When p_from
-- or p_to is supplied it takes precedence over p_days. The range is inclusive of
-- the whole p_to day (the upper bound is p_to + 1 day, exclusive).
-- Replaces the admin_analytics(int) signature from 0020.
-- ============================================================================
drop function if exists public.admin_analytics(int);

create or replace function public.admin_analytics(
  p_days int  default null,
  p_from date default null,
  p_to   date default null
)
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare result jsonb; since timestamptz; until timestamptz;
begin
  if not public.is_admin() then return null; end if;

  -- Lower bound: an explicit p_from wins; else the p_days window; else all-time.
  since := case
             when p_from is not null then p_from::timestamptz
             when p_days is not null then now() - (p_days || ' days')::interval
             else '-infinity'::timestamptz
           end;
  -- Upper bound: explicit p_to, inclusive of that whole day; else open-ended.
  until := case
             when p_to is not null then (p_to + 1)::timestamptz
             else 'infinity'::timestamptz
           end;

  select jsonb_build_object(
    'days', p_days,
    'from', p_from,
    'to', p_to,
    'total',           (select count(*) from public.events where created_at >= since and created_at < until),
    'screen_views',    (select count(*) from public.events where type='screen_view' and created_at >= since and created_at < until),
    'profile_views',   (select count(*) from public.events where type='profile_viewed' and created_at >= since and created_at < until),
    'unique_users',    (select count(distinct user_id) from public.events where user_id is not null and created_at >= since and created_at < until),
    'unique_visitors', (select count(distinct data->>'vid') from public.events where data ? 'vid' and data->>'vid' <> '' and created_at >= since and created_at < until),
    'signups',         (select count(*) from public.events where type='signup' and created_at >= since and created_at < until),
    'last_7d',         (select count(*) from public.events where created_at > now() - interval '7 days'),
    'by_type', coalesce((select jsonb_agg(jsonb_build_object('type',type,'count',c) order by c desc)
      from (select type, count(*) c from public.events where created_at >= since and created_at < until group by type) t), '[]'::jsonb),
    'top_screens', coalesce((select jsonb_agg(jsonb_build_object('screen',screen,'count',c) order by c desc)
      from (select coalesce(data->>'screen','(unknown)') as screen, count(*) c from public.events
            where type='screen_view' and created_at >= since and created_at < until group by 1 order by count(*) desc limit 12) s), '[]'::jsonb),
    'top_referrers', coalesce((select jsonb_agg(jsonb_build_object('ref',ref,'count',c) order by c desc)
      from (select case
                     when coalesce(data->>'ref','') = '' then 'Direct / none'
                     else coalesce(nullif(regexp_replace(data->>'ref', '^https?://([^/]+).*$', '\1'), ''), data->>'ref')
                   end as ref,
                   count(distinct coalesce(data->>'vid', id::text)) c
            from public.events
            where type='screen_view' and created_at >= since and created_at < until
            group by 1 order by 2 desc limit 12) rf), '[]'::jsonb),
    'by_day', coalesce((select jsonb_agg(jsonb_build_object('day', d.day, 'count', d.c) order by d.day)
      from (select to_char(date_trunc('day',created_at),'YYYY-MM-DD') as day, count(*) as c from public.events
            where created_at >= (case when since = '-infinity'::timestamptz then now() - interval '30 days' else since end)
              and created_at < until
            group by 1) d), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(jsonb_build_object(
        'created_at', e.created_at, 'type', e.type,
        'detail', coalesce(e.data->>'screen', case when e.data ? 'shared' then (case when (e.data->>'shared')::boolean then 'shared link' else 'own' end) else '' end),
        'account', (select u.email from auth.users u where u.id = e.user_id),
        'ip', e.data->>'ip', 'city', e.data->>'city', 'country', e.data->>'country', 'ua', e.data->>'ua'
      ) order by e.created_at desc)
      from (select * from public.events where created_at >= since and created_at < until order by created_at desc limit 100) e), '[]'::jsonb)
  ) into result;
  return result;
end; $$;

grant execute on function public.admin_analytics(int, date, date) to authenticated;
