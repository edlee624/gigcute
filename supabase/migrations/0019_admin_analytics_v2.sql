-- ============================================================================
-- GigCute — admin analytics v2
-- Adds a date filter, resolves the account (email) per event, surfaces the
-- visitor meta (browser UA, IP, city/country) the client now records, and adds
-- an admin-only reset. All admin-gated; the events table stays admin-read-only.
-- ============================================================================

create or replace function public.admin_analytics(p_days int default null)
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare result jsonb; since timestamptz;
begin
  if not public.is_admin() then
    return null;
  end if;
  since := case when p_days is null then '-infinity'::timestamptz
                else now() - (p_days || ' days')::interval end;

  select jsonb_build_object(
    'days',          p_days,
    'total',         (select count(*) from public.events where created_at >= since),
    'screen_views',  (select count(*) from public.events where type = 'screen_view' and created_at >= since),
    'profile_views', (select count(*) from public.events where type = 'profile_viewed' and created_at >= since),
    'unique_users',  (select count(distinct user_id) from public.events where user_id is not null and created_at >= since),
    'last_7d',       (select count(*) from public.events where created_at > now() - interval '7 days'),
    'by_type', coalesce((
      select jsonb_agg(jsonb_build_object('type', type, 'count', c) order by c desc)
      from (select type, count(*) c from public.events where created_at >= since group by type) t), '[]'::jsonb),
    'top_screens', coalesce((
      select jsonb_agg(jsonb_build_object('screen', screen, 'count', c) order by c desc)
      from (select coalesce(data->>'screen','(unknown)') as screen, count(*) c
            from public.events where type = 'screen_view' and created_at >= since
            group by 1 order by count(*) desc limit 12) s), '[]'::jsonb),
    'by_day', coalesce((
      select jsonb_agg(jsonb_build_object('day', day, 'count', c) order by day)
      from (select to_char(date_trunc('day', created_at), 'YYYY-MM-DD') as day, count(*) c
            from public.events
            where created_at > now() - (coalesce(p_days, 30) || ' days')::interval
            group by 1) d), '[]'::jsonb),
    'recent', coalesce((
      select jsonb_agg(jsonb_build_object(
        'created_at', e.created_at,
        'type', e.type,
        'detail', coalesce(e.data->>'screen', case when e.data ? 'shared' then (case when (e.data->>'shared')::boolean then 'shared link' else 'own' end) else '' end),
        'account', (select u.email from auth.users u where u.id = e.user_id),
        'ip', e.data->>'ip',
        'city', e.data->>'city',
        'country', e.data->>'country',
        'ua', e.data->>'ua'
      ) order by e.created_at desc)
      from (select * from public.events where created_at >= since order by created_at desc limit 100) e), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

-- Admin-only reset (clears the events log). Returns rows deleted, or -1 if not admin.
create or replace function public.admin_reset_events()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_admin() then return -1; end if;
  delete from public.events;
  get diagnostics n = row_count;
  return n;
end;
$$;

grant execute on function public.admin_analytics(int) to authenticated;
grant execute on function public.admin_reset_events() to authenticated;
