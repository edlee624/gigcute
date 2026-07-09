-- ============================================================================
-- GigCute — plan tiers + limit enforcement (Build 1).
--   companies.plan drives three limits, defined as data in plan_limits:
--     * max_active_postings   — live (status='active') postings per company
--     * max_chats_per_posting — ongoing (not-ended) conversations per posting
--     * max_invites_per_30d   — invites created in a rolling 30-day window
--   Enforcement is airtight (BEFORE-INSERT/UPDATE triggers on postings, invites,
--   conversations) so no client can bypass it. RPCs surface usage so the UI can
--   warn recruiters BEFORE they hit a wall. Admins bypass all limits.
--   Tiers/pricing are intentionally NOT exposed to users yet (see Build 2).
-- ============================================================================

alter table public.companies add column if not exists plan text not null default 'free';

create table if not exists public.plan_limits (
  plan                   text primary key,
  max_active_postings    int not null,
  max_chats_per_posting  int not null,
  max_invites_per_30d    int not null
);

insert into public.plan_limits (plan, max_active_postings, max_chats_per_posting, max_invites_per_30d) values
  ('free',     2,  5,  10),
  ('starter',  5, 10,  20),
  ('pro',     15, 30,  60),
  ('god',     40, 50, 200)
on conflict (plan) do update set
  max_active_postings   = excluded.max_active_postings,
  max_chats_per_posting = excluded.max_chats_per_posting,
  max_invites_per_30d   = excluded.max_invites_per_30d;

alter table public.plan_limits enable row level security;
drop policy if exists "plan_limits: read" on public.plan_limits;
create policy "plan_limits: read" on public.plan_limits for select using (true);

-- Resolve a company's limits, falling back to the 'free' row for unknown/missing plans.
create or replace function public.plan_limits_for(p_company uuid)
returns public.plan_limits language sql stable security definer set search_path = public as $$
  select pl.* from public.plan_limits pl
  where pl.plan = coalesce(
    (select co.plan from public.companies co
       join public.plan_limits pl2 on pl2.plan = co.plan
      where co.id = p_company),
    'free');
$$;

-- ---- Enforcement triggers --------------------------------------------------

-- Active postings per company. Fires only when a posting BECOMES active.
create or replace function public.enforce_posting_limit()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_max int;
begin
  if public.is_admin() then return NEW; end if;
  if NEW.status = 'active' and (TG_OP = 'INSERT' or OLD.status is distinct from 'active') then
    v_max := (public.plan_limits_for(NEW.company_id)).max_active_postings;
    if (select count(*) from public.postings
          where company_id = NEW.company_id and status = 'active' and id <> NEW.id) >= v_max then
      raise exception 'You have reached your plan limit of % active postings. Pause or let a posting expire to publish another.', v_max
        using errcode = 'GC010';
    end if;
  end if;
  return NEW;
end $$;
drop trigger if exists trg_enforce_posting_limit on public.postings;
create trigger trg_enforce_posting_limit before insert or update on public.postings
  for each row execute function public.enforce_posting_limit();

-- Invites created in a rolling 30-day window, per company. INSERT only, so
-- re-inviting the same candidate (an upsert UPDATE) does not consume quota.
create or replace function public.enforce_invite_limit()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_co uuid; v_max int;
begin
  if public.is_admin() then return NEW; end if;
  select company_id into v_co from public.postings where id = NEW.posting_id;
  v_max := (public.plan_limits_for(v_co)).max_invites_per_30d;
  if (select count(*) from public.invites i join public.postings p on p.id = i.posting_id
        where p.company_id = v_co and i.created_at > now() - interval '30 days') >= v_max then
    raise exception 'You have reached your plan limit of % invites in 30 days.', v_max
      using errcode = 'GC020';
  end if;
  return NEW;
end $$;
drop trigger if exists trg_enforce_invite_limit on public.invites;
create trigger trg_enforce_invite_limit before insert on public.invites
  for each row execute function public.enforce_invite_limit();

-- Ongoing (not-ended) conversations per posting. Ended/archived chats free a slot.
create or replace function public.enforce_chat_limit()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_co uuid; v_max int;
begin
  if public.is_admin() then return NEW; end if;
  select company_id into v_co from public.postings where id = NEW.posting_id;
  v_max := (public.plan_limits_for(v_co)).max_chats_per_posting;
  if (select count(*) from public.conversations
        where posting_id = NEW.posting_id and ended_at is null) >= v_max then
    raise exception 'This posting has reached its plan limit of % ongoing chats. End a chat to start another.', v_max
      using errcode = 'GC030';
  end if;
  return NEW;
end $$;
drop trigger if exists trg_enforce_chat_limit on public.conversations;
create trigger trg_enforce_chat_limit before insert on public.conversations
  for each row execute function public.enforce_chat_limit();

-- ---- Usage RPCs (feed the UI warnings) -------------------------------------

-- Account-level usage for the current recruiter (summed across their companies).
create or replace function public.recruiter_limits()
returns table(plan text, max_active_postings int, max_chats_per_posting int, max_invites_per_30d int,
              used_active_postings int, used_invites_30d int)
language sql stable security definer set search_path = public as $$
  with cos as (select id, plan from public.companies where owner_id = auth.uid())
  select
    coalesce(max(c.plan), 'free'),
    coalesce(max(pl.max_active_postings),   (select max_active_postings   from public.plan_limits where plan='free')),
    coalesce(max(pl.max_chats_per_posting), (select max_chats_per_posting from public.plan_limits where plan='free')),
    coalesce(max(pl.max_invites_per_30d),   (select max_invites_per_30d   from public.plan_limits where plan='free')),
    (select count(*)::int from public.postings p where p.company_id in (select id from cos) and p.status='active'),
    (select count(*)::int from public.invites i join public.postings p on p.id=i.posting_id
       where p.company_id in (select id from cos) and i.created_at > now() - interval '30 days')
  from cos c left join public.plan_limits pl on pl.plan = c.plan;
$$;
grant execute on function public.recruiter_limits() to authenticated;

-- Ongoing-chat usage for one posting the caller owns.
create or replace function public.posting_chat_usage(p_posting uuid)
returns table(used int, max int)
language sql stable security definer set search_path = public as $$
  select
    (select count(*)::int from public.conversations where posting_id = p_posting and ended_at is null),
    (public.plan_limits_for((select company_id from public.postings where id = p_posting))).max_chats_per_posting
  where public.owns_posting(p_posting);
$$;
grant execute on function public.posting_chat_usage(uuid) to authenticated;
