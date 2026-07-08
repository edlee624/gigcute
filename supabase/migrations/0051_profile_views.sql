-- ============================================================================
-- GigCute — profile_views: real "people viewed your profile" tracking
-- Records when a logged-in user views SOMEONE ELSE's seeker profile. Self-views
-- and anonymous viewers are never recorded. Deduped to one row per
-- viewer/seeker/day so the weekly count reflects distinct people, not refreshes.
-- ============================================================================
create table if not exists public.profile_views (
  seeker_id uuid not null references public.profiles(id) on delete cascade,
  viewer_id uuid not null references public.profiles(id) on delete cascade,
  view_day  date not null default (now() at time zone 'utc')::date,
  viewed_at timestamptz not null default now(),
  primary key (seeker_id, viewer_id, view_day)
);
alter table public.profile_views enable row level security;
create index if not exists profile_views_seeker_idx on public.profile_views (seeker_id, viewed_at desc);

-- Owner can read who/how-many viewed them; writes go only through the RPC below.
drop policy if exists "profile_views: owner read" on public.profile_views;
create policy "profile_views: owner read" on public.profile_views for select
  using (seeker_id = auth.uid());

-- Log a view. No-ops for anonymous callers and self-views (the two exclusions).
create or replace function public.log_profile_view(p_seeker uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or auth.uid() = p_seeker then return; end if;
  insert into public.profile_views (seeker_id, viewer_id)
  values (p_seeker, auth.uid())
  on conflict (seeker_id, viewer_id, view_day) do update set viewed_at = now();
end $$;

-- Distinct people who viewed the caller's profile in the last p_days days.
create or replace function public.my_profile_views(p_days int default 7)
returns int language sql stable security definer set search_path = public as $$
  select count(distinct viewer_id)::int
  from public.profile_views
  where seeker_id = auth.uid()
    and viewer_id <> seeker_id                 -- never count self-views
    and viewed_at >= now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 365)));
$$;

grant execute on function public.log_profile_view(uuid) to anon, authenticated;
grant execute on function public.my_profile_views(int) to authenticated;
