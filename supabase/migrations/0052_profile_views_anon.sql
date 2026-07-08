-- ============================================================================
-- GigCute — count anonymous profile views too (shared-link visitors)
-- Supersedes 0051's logged-in-only design. A view is now keyed by `viewer_key`:
-- the auth uid for signed-in viewers, or a client-generated visitor token for
-- anonymous ones — so link visitors count as distinct people (deduped per day).
-- Self-views are still never counted. Table was empty, so we recreate it.
-- ============================================================================
drop function if exists public.log_profile_view(uuid);
drop function if exists public.my_profile_views(int);
drop table if exists public.profile_views;

create table public.profile_views (
  seeker_id  uuid not null references public.profiles(id) on delete cascade,
  viewer_key text not null,          -- auth uid (signed in) OR visitor token (anon)
  is_anon    boolean not null default false,
  view_day   date not null default (now() at time zone 'utc')::date,
  viewed_at  timestamptz not null default now(),
  primary key (seeker_id, viewer_key, view_day)
);
alter table public.profile_views enable row level security;
create index profile_views_seeker_idx on public.profile_views (seeker_id, viewed_at desc);

drop policy if exists "profile_views: owner read" on public.profile_views;
create policy "profile_views: owner read" on public.profile_views for select
  using (seeker_id = auth.uid());

-- Log a view. Signed-in viewers key by uid; anonymous by the passed visitor token.
-- No-ops when the viewer can't be identified or the viewer is the owner (self).
create or replace function public.log_profile_view(p_seeker uuid, p_visitor text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_key text; v_anon boolean;
begin
  if auth.uid() is not null then v_key := auth.uid()::text; v_anon := false;
  else v_key := nullif(btrim(coalesce(p_visitor, '')), ''); v_anon := true;
  end if;
  if v_key is null then return; end if;
  if v_key = p_seeker::text then return; end if;      -- never count self-views
  insert into public.profile_views (seeker_id, viewer_key, is_anon)
  values (p_seeker, v_key, v_anon)
  on conflict (seeker_id, viewer_key, view_day) do update set viewed_at = now();
end $$;

-- Distinct people (signed-in + anonymous) who viewed the caller in the window.
create or replace function public.my_profile_views(p_days int default 7)
returns int language sql stable security definer set search_path = public as $$
  select count(distinct viewer_key)::int
  from public.profile_views
  where seeker_id = auth.uid()
    and viewer_key <> auth.uid()::text
    and viewed_at >= now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 365)));
$$;

grant execute on function public.log_profile_view(uuid, text) to anon, authenticated;
grant execute on function public.my_profile_views(int) to authenticated;
