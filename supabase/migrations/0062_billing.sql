-- ============================================================================
-- GigCute — billing scaffold (Build 2, HIDDEN). NOT the source of truth for
-- limits (that's companies.plan + plan_limits from 0061). This just records the
-- Stripe subscription so the webhook can keep companies.plan in sync.
--   * DO NOT enable the upgrade UI (GC_SHOW_UPGRADE) until pricing is set and the
--     create-checkout / stripe-webhook edge functions are deployed with keys.
-- ============================================================================
create table if not exists public.subscriptions (
  company_id             uuid primary key references public.companies(id) on delete cascade,
  plan                   text not null default 'free',
  stripe_customer_id     text,
  stripe_subscription_id text,
  status                 text,            -- Stripe sub status: active, past_due, canceled, …
  current_period_end     timestamptz,
  updated_at             timestamptz not null default now()
);
alter table public.subscriptions enable row level security;

-- A company owner may READ their own subscription (never write — only the webhook,
-- via service role, mutates it).
drop policy if exists "subscriptions: owner read" on public.subscriptions;
create policy "subscriptions: owner read" on public.subscriptions for select
  using (exists (select 1 from public.companies co where co.id = company_id and co.owner_id = auth.uid()));

-- Keep companies.plan in lockstep with the subscription. A subscription that is
-- not currently active falls back to 'free'.
create or replace function public.sync_company_plan()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.companies
     set plan = case when NEW.status = 'active' then NEW.plan else 'free' end
   where id = NEW.company_id;
  return NEW;
end $$;
drop trigger if exists trg_sync_company_plan on public.subscriptions;
create trigger trg_sync_company_plan after insert or update on public.subscriptions
  for each row execute function public.sync_company_plan();
