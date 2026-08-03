-- ============================================================================
-- GigCute ATS — scheduling & conferencing integrations (Phase 2).
--
-- Recruiters connect the tools they already schedule with:
--   calendly      booking page (candidate self-schedules)
--   google_meet   video room
--   teams         video room
--   zoom          video room
--
-- Two modes per provider:
--   'link'   the recruiter saves their personal room / booking URL. Works with
--            zero setup and is what the UI uses today.
--   'oauth'  the account is connected via OAuth (Calendly first). Tokens live
--            in integration_tokens, which has RLS ON and NO policies, so only
--            the service role (edge functions) can read them — never the client.
--
-- Links are shown to candidates, so they are validated: https only, and the
-- host must match a per-provider allowlist. That blocks javascript:/data: URLs
-- and credential-style hosts like https://calendly.com@evil.com.
-- ============================================================================

do $$ begin create type integration_provider as enum ('calendly','google_meet','teams','zoom'); exception when duplicate_object then null; end $$;

-- ---- URL host extraction (userinfo-safe) ----------------------------------
-- https://calendly.com@evil.com/x  ->  evil.com   (the real host)
create or replace function public.url_host(p_url text)
returns text language sql immutable as $$
  select lower(split_part(
           regexp_replace(
             split_part(regexp_replace(btrim(coalesce(p_url,'')), '^[Hh][Tt][Tt][Pp][Ss]://', ''), '/', 1),
             '^.*@', ''),
           ':', 1));
$$;

create or replace function public.integration_link_ok(p_provider integration_provider, p_url text)
returns boolean language sql immutable as $$
  select case
    when p_url is null or btrim(p_url) = '' then false
    when btrim(p_url) !~ '^[Hh][Tt][Tt][Pp][Ss]://' then false
    else (select case p_provider
        when 'calendly'    then h = 'calendly.com'         or h like '%.calendly.com'
        when 'google_meet' then h = 'meet.google.com'
        when 'teams'       then h in ('teams.microsoft.com','teams.live.com') or h like '%.teams.microsoft.com'
        when 'zoom'        then h = 'zoom.us'              or h like '%.zoom.us'
        else false end
      from (select public.url_host(p_url) h) x)
  end;
$$;

-- ---- tables ---------------------------------------------------------------
create table if not exists public.integrations (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  company_id uuid references public.companies(id) on delete set null,
  provider integration_provider not null,
  mode text not null default 'link' check (mode in ('link','oauth')),
  status text not null default 'active' check (status in ('active','revoked','error')),
  display_name text,
  link text,
  external_user_uri text,
  external_org_uri text,
  meta jsonb not null default '{}'::jsonb,
  connected_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (profile_id, provider),
  constraint integrations_link_valid check (link is null or public.integration_link_ok(provider, link))
);
create index if not exists integrations_profile_idx on public.integrations(profile_id);

alter table public.integrations enable row level security;
revoke all on public.integrations from anon;
grant select, insert, update, delete on public.integrations to authenticated;
drop policy if exists integrations_own on public.integrations;
create policy integrations_own on public.integrations for all
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());

drop trigger if exists integrations_touch on public.integrations;
create trigger integrations_touch before update on public.integrations
  for each row execute function public.touch_updated_at();

-- OAuth tokens. RLS ON with NO policies => unreachable from anon/authenticated;
-- only the service role (edge functions) bypasses RLS.
create table if not exists public.integration_tokens (
  integration_id uuid primary key references public.integrations(id) on delete cascade,
  access_token text,
  refresh_token text,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.integration_tokens enable row level security;
revoke all on public.integration_tokens from anon, authenticated;

-- Short-lived OAuth state nonces (CSRF protection for the redirect dance).
create table if not exists public.integration_oauth_states (
  state text primary key,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  provider integration_provider not null,
  redirect_to text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '15 minutes'
);
alter table public.integration_oauth_states enable row level security;
revoke all on public.integration_oauth_states from anon, authenticated;

-- ---- interviews carry the meeting provider + join link --------------------
alter table public.interviews add column if not exists provider integration_provider;
alter table public.interviews add column if not exists join_url text;
alter table public.interviews add column if not exists external_event_uri text;
create unique index if not exists interviews_external_event_uq
  on public.interviews(external_event_uri) where external_event_uri is not null;

-- ---- RPCs -----------------------------------------------------------------
-- Never returns tokens: only connection status + the shareable link.
create or replace function public.integrations_list()
returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'provider', provider, 'mode', mode, 'status', status,
    'display_name', display_name, 'link', link,
    'connected_at', connected_at) order by provider), '[]'::jsonb)
  from public.integrations where profile_id = auth.uid();
$$;
grant execute on function public.integrations_list() to authenticated;

create or replace function public.integration_save_link(p_provider integration_provider, p_link text, p_display_name text default null)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_co uuid; v_link text;
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  v_link := btrim(coalesce(p_link,''));
  if v_link = '' then raise exception 'Paste your link first.'; end if;
  if not public.integration_link_ok(p_provider, v_link) then
    raise exception 'That doesn''t look like a % link. Use the https:// address your account gives you.',
      case p_provider when 'calendly' then 'Calendly' when 'google_meet' then 'Google Meet'
                      when 'teams' then 'Microsoft Teams' else 'Zoom' end;
  end if;
  select id into v_co from public.companies where owner_id = auth.uid() order by created_at limit 1;
  if v_co is null then select company_id into v_co from public.company_members where profile_id = auth.uid() limit 1; end if;

  insert into public.integrations(profile_id, company_id, provider, mode, status, link, display_name)
  values (auth.uid(), v_co, p_provider, 'link', 'active', v_link, nullif(btrim(coalesce(p_display_name,'')),''))
  on conflict (profile_id, provider) do update
    set link = excluded.link, display_name = coalesce(excluded.display_name, public.integrations.display_name),
        mode = case when public.integrations.mode = 'oauth' then 'oauth' else 'link' end,
        status = 'active', company_id = coalesce(public.integrations.company_id, excluded.company_id);
  return jsonb_build_object('ok', true, 'provider', p_provider);
end $$;
grant execute on function public.integration_save_link(integration_provider, text, text) to authenticated;

create or replace function public.integration_disconnect(p_provider integration_provider)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
begin
  delete from public.integrations where profile_id = auth.uid() and provider = p_provider;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.integration_disconnect(integration_provider) to authenticated;

-- ---- scheduling now records the provider + join link ----------------------
-- Replaces the 0094 signature; the two new args default so older clients still work.
drop function if exists public.ats_schedule_interview(uuid, uuid, timestamptz, int, uuid, text, text);
create or replace function public.ats_schedule_interview(
  p_app uuid, p_stage uuid, p_when timestamptz, p_duration int, p_interviewer uuid,
  p_location text, p_notes text,
  p_provider integration_provider default null, p_join_url text default null)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_co uuid; v_id uuid; v_iname text; v_join text; v_loc text;
begin
  select company_id into v_co from public.applications where id=p_app;
  if v_co is null or not public.company_can(v_co,'schedule') then raise exception 'You don''t have permission to schedule interviews.'; end if;
  if p_when is null then raise exception 'Pick a date and time.'; end if;

  v_join := nullif(btrim(coalesce(p_join_url,'')),'');
  -- Fall back to the interviewer's saved room for that provider.
  if v_join is null and p_provider is not null then
    select link into v_join from public.integrations
     where profile_id = coalesce(p_interviewer, auth.uid()) and provider = p_provider and status='active';
  end if;
  if v_join is not null and p_provider is not null and not public.integration_link_ok(p_provider, v_join) then
    raise exception 'That meeting link doesn''t look right for the provider you picked.';
  end if;

  v_loc := nullif(btrim(coalesce(p_location,'')),'');
  if v_loc is null and p_provider is not null then
    v_loc := case p_provider when 'calendly' then 'Calendly' when 'google_meet' then 'Google Meet'
                             when 'teams' then 'Microsoft Teams' else 'Zoom' end;
  end if;

  insert into public.interviews(company_id, application_id, stage_id, scheduled_at, duration_min,
                                interviewer_id, location, notes, created_by, provider, join_url)
    values (v_co, p_app, p_stage, p_when, coalesce(nullif(p_duration,0),45), p_interviewer,
            v_loc, nullif(btrim(coalesce(p_notes,'')),''), auth.uid(), p_provider, v_join)
    returning id into v_id;

  select full_name into v_iname from public.profiles where id=p_interviewer;
  insert into public.application_activities(company_id, application_id, actor_id, type, body)
    values (v_co, p_app, auth.uid(), 'note',
            'Interview scheduled with ' || coalesce(nullif(v_iname,''),'the team') ||
            ' for ' || to_char(p_when at time zone 'UTC','Mon DD, HH24:MI') || ' UTC' ||
            coalesce(' · ' || v_loc, ''));
  return jsonb_build_object('id', v_id, 'join_url', v_join);
end $$;
grant execute on function public.ats_schedule_interview(uuid, uuid, timestamptz, int, uuid, text, text, integration_provider, text) to authenticated;

-- ats_interviews: surface the provider + join link on each row.
create or replace function public.ats_interviews(p_app uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_co uuid;
begin
  select company_id into v_co from public.applications where id=p_app;
  if v_co is null or not public.is_company_member(v_co) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
     'id', i.id, 'scheduled_at', i.scheduled_at, 'duration_min', i.duration_min,
     'interviewer', pr.full_name, 'location', i.location, 'notes', i.notes,
     'status', i.status, 'stage', st.name,
     'provider', i.provider, 'join_url', i.join_url) order by i.scheduled_at)
   from public.interviews i
   left join public.profiles pr on pr.id = i.interviewer_id
   left join public.job_stages st on st.id = i.stage_id
   where i.application_id = p_app and i.status <> 'canceled'), '[]'::jsonb);
end $$;
grant execute on function public.ats_interviews(uuid) to authenticated;
