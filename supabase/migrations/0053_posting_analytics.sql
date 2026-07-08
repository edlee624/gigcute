-- ============================================================================
-- GigCute — posting analytics (views + audience breakdown)
-- Mirrors profile_views for postings: records who viewed a posting (signed-in
-- keyed by uid, anonymous by a client visitor token), excluding the owner.
-- posting_stats returns headline counts; posting_audience returns an AGGREGATE
-- professional breakdown (work setup, experience band) of signed-in viewers,
-- split by whether they liked the posting — never individual identities.
-- ============================================================================
create table if not exists public.posting_views (
  posting_id uuid not null references public.postings(id) on delete cascade,
  viewer_key text not null,                                   -- uid or anon token
  viewer_id  uuid references public.profiles(id) on delete set null,  -- set for signed-in
  is_anon    boolean not null default false,
  view_day   date not null default (now() at time zone 'utc')::date,
  viewed_at  timestamptz not null default now(),
  primary key (posting_id, viewer_key, view_day)
);
alter table public.posting_views enable row level security;
create index if not exists posting_views_posting_idx on public.posting_views (posting_id, viewed_at desc);

drop policy if exists "posting_views: owner read" on public.posting_views;
create policy "posting_views: owner read" on public.posting_views for select
  using (public.owns_posting(posting_id));

-- Record a view. Owner-views and unidentifiable callers are skipped.
create or replace function public.log_posting_view(p_posting uuid, p_visitor text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_key text; v_uid uuid; v_anon boolean;
begin
  if public.owns_posting(p_posting) then return; end if;
  if auth.uid() is not null then v_key := auth.uid()::text; v_uid := auth.uid(); v_anon := false;
  else v_key := nullif(btrim(coalesce(p_visitor, '')), ''); v_uid := null; v_anon := true;
  end if;
  if v_key is null then return; end if;
  insert into public.posting_views (posting_id, viewer_key, viewer_id, is_anon)
  values (p_posting, v_key, v_uid, v_anon)
  on conflict (posting_id, viewer_key, view_day) do update set viewed_at = now();
end $$;

-- Headline stats for a posting the caller owns.
create or replace function public.posting_stats(p_posting uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not public.owns_posting(p_posting) then null else jsonb_build_object(
    'views',      (select count(distinct viewer_key) from public.posting_views where posting_id = p_posting),
    'views_7d',   (select count(distinct viewer_key) from public.posting_views where posting_id = p_posting and viewed_at >= now() - interval '7 days'),
    'interested', (select count(*) from public.seeker_interest where posting_id = p_posting)
  ) end;
$$;

-- Aggregate professional breakdown of SIGNED-IN viewers, split by liked vs not.
-- Returns distributions only (no identities). The client hides small groups.
create or replace function public.posting_audience(p_posting uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with g as (
    select
      exists(select 1 from public.seeker_interest si where si.posting_id = p_posting and si.seeker_id = v.viewer_id) as liked,
      coalesce(nullif(btrim(sp.work_setup), ''), 'Unspecified') as ws,
      case when sp.exp_years is null then 'Unknown'
           when sp.exp_years < 2 then '0-2 yrs'
           when sp.exp_years < 5 then '2-5 yrs'
           when sp.exp_years < 10 then '5-10 yrs'
           else '10+ yrs' end as exp
    from (select distinct viewer_id from public.posting_views where posting_id = p_posting and viewer_id is not null) v
    join public.seeker_profiles sp on sp.profile_id = v.viewer_id
    where public.owns_posting(p_posting)
  )
  select jsonb_build_object(
    'liked_count', count(*) filter (where liked),
    'other_count', count(*) filter (where not liked),
    'work_setup', jsonb_build_object(
      'liked', (select coalesce(jsonb_object_agg(ws, c), '{}') from (select ws, count(*) c from g where liked group by ws) t),
      'other', (select coalesce(jsonb_object_agg(ws, c), '{}') from (select ws, count(*) c from g where not liked group by ws) t)),
    'experience', jsonb_build_object(
      'liked', (select coalesce(jsonb_object_agg(exp, c), '{}') from (select exp, count(*) c from g where liked group by exp) t),
      'other', (select coalesce(jsonb_object_agg(exp, c), '{}') from (select exp, count(*) c from g where not liked group by exp) t))
  ) from g;
$$;

grant execute on function public.log_posting_view(uuid, text) to anon, authenticated;
grant execute on function public.posting_stats(uuid) to authenticated;
grant execute on function public.posting_audience(uuid) to authenticated;
