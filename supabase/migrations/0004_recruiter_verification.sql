-- ============================================================================
-- GigCute — recruiter verification
-- Goal: stop fake recruiter/company accounts from reaching candidate data.
--
-- Model:
--   * A company is auto-verified when its owner's email is on a real business
--     domain (not a free/personal or disposable provider). Free/disposable
--     domains -> verified=false, pending manual admin review.
--   * Clients can NEVER set/raise `verified` themselves (trigger enforces it);
--     only the insert logic or an admin can.
--   * Candidate PII (seeker profiles + work history + education + prompt answers,
--     and who-is-interested lists) is readable by recruiters ONLY when they
--     belong to a verified company. Email-confirmation (Supabase) still gates
--     account activation on top of this.
-- ============================================================================

-- ---- Free / disposable email-domain blocklist -----------------------------
create table public.blocked_email_domains (
  domain text primary key
);
alter table public.blocked_email_domains enable row level security;
create policy "blocked domains: read all" on public.blocked_email_domains for select using (true);

insert into public.blocked_email_domains (domain) values
  -- free / personal providers
  ('gmail.com'),('googlemail.com'),('yahoo.com'),('ymail.com'),('outlook.com'),('hotmail.com'),
  ('live.com'),('msn.com'),('icloud.com'),('me.com'),('mac.com'),('aol.com'),('gmx.com'),('gmx.net'),
  ('mail.com'),('proton.me'),('protonmail.com'),('pm.me'),('yandex.com'),('yandex.ru'),('zoho.com'),
  ('fastmail.com'),('hey.com'),('tutanota.com'),('hotmail.co.uk'),('yahoo.co.uk'),('comcast.net'),('verizon.net'),
  -- disposable / throwaway
  ('mailinator.com'),('tempmail.com'),('temp-mail.org'),('guerrillamail.com'),('10minutemail.com'),
  ('throwaway.email'),('trashmail.com'),('getnada.com'),('dispostable.com'),('yopmail.com'),
  ('sharklasers.com'),('tempmail.io'),('maildrop.cc'),('mintemail.com'),('fakeinbox.com'),('emailondeck.com')
on conflict (domain) do nothing;

-- ---- Company verification columns -----------------------------------------
alter table public.companies
  add column if not exists verified     boolean not null default false,
  add column if not exists verified_at  timestamptz,
  add column if not exists email_domain text;

-- ---- Helpers ---------------------------------------------------------------
-- A business domain is one that is present and NOT on the blocklist.
create or replace function public.is_business_domain(p_domain text)
returns boolean language sql stable security definer set search_path = public as $$
  select p_domain is not null and p_domain <> ''
     and not exists (select 1 from public.blocked_email_domains b where b.domain = lower(p_domain));
$$;

-- Is the current user a member/owner of at least one VERIFIED company?
create or replace function public.is_verified_recruiter()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.companies c
    where c.verified = true
      and ( c.owner_id = auth.uid()
            or exists (select 1 from public.company_members m
                       where m.company_id = c.id and m.profile_id = auth.uid()) )
  );
$$;

-- ---- Verification trigger (the backstop) ----------------------------------
-- On INSERT: derive the owner's email domain and auto-verify business domains.
-- On UPDATE: non-admins cannot change verified/verified_at/email_domain.
create or replace function public.guard_company_verification()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_email text; v_domain text;
begin
  if tg_op = 'INSERT' then
    select email into v_email from auth.users where id = new.owner_id;
    v_domain := lower(split_part(coalesce(v_email, ''), '@', 2));
    new.email_domain := v_domain;
    new.verified := public.is_business_domain(v_domain);
    new.verified_at := case when new.verified then now() else null end;
  else
    if not public.is_admin() then
      new.verified     := old.verified;
      new.verified_at  := old.verified_at;
      new.email_domain := old.email_domain;
    end if;
  end if;
  return new;
end; $$;

create trigger company_verification
  before insert or update on public.companies
  for each row execute function public.guard_company_verification();

-- Admin manual verification (for legit recruiters on personal email, appeals).
create or replace function public.admin_set_company_verified(p_company uuid, p_verified boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not authorized'; end if;
  update public.companies
    set verified = p_verified, verified_at = case when p_verified then now() else null end
    where id = p_company;
end; $$;

-- ---- Gate candidate PII behind verified-recruiter status -------------------
-- Replace the permissive read policies from 0001 so candidate data is only
-- visible to the candidate themselves, a VERIFIED recruiter, or an admin.
drop policy if exists "seeker: read visible" on public.seeker_profiles;
create policy "seeker: read gated" on public.seeker_profiles for select
  using (profile_id = auth.uid() or public.is_verified_recruiter() or public.is_admin());

drop policy if exists "work_history: read" on public.work_history;
create policy "work_history: read gated" on public.work_history for select
  using (seeker_id = auth.uid() or public.is_verified_recruiter() or public.is_admin());

drop policy if exists "education: read" on public.education;
create policy "education: read gated" on public.education for select
  using (seeker_id = auth.uid() or public.is_verified_recruiter() or public.is_admin());

drop policy if exists "prompt_answers: read" on public.seeker_prompt_answers;
create policy "prompt_answers: read gated" on public.seeker_prompt_answers for select
  using (seeker_id = auth.uid() or public.is_verified_recruiter() or public.is_admin());

-- Who-is-interested lists also require a verified recruiter.
drop policy if exists "seeker_interest: recruiter read" on public.seeker_interest;
create policy "seeker_interest: recruiter read" on public.seeker_interest for select
  using (seeker_id = auth.uid() or (public.owns_posting(posting_id) and public.is_verified_recruiter()));
