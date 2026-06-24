-- ============================================================================
-- GigCute — recruiter ID verification (for personal/flagged emails)
-- A recruiter on a personal email can upload one photo of themselves holding
-- their government ID. This is SENSITIVE: it goes in a PRIVATE bucket (no public
-- read) and is reviewable only by the uploader and admins. An admin approves the
-- request, which then verifies the company (admin_set_company_verified).
-- ============================================================================

-- Private bucket for verification photos (note: public = false).
insert into storage.buckets (id, name, public)
values ('verification', 'verification', false)
on conflict (id) do nothing;

-- Files live at verification/<uid>/<filename>. Only the owner can upload, and
-- only the owner or an admin can read. No public read policy exists.
create policy "verif: owner insert"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'verification' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "verif: owner or admin read"
  on storage.objects for select to authenticated
  using (bucket_id = 'verification' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

create policy "verif: owner delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'verification' and (storage.foldername(name))[1] = auth.uid()::text);

-- Verification requests (admin review queue).
create table public.verification_requests (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid not null references public.profiles(id) on delete cascade,
  company_id  uuid references public.companies(id) on delete set null,
  doc_path    text not null,
  status      text not null default 'pending',   -- pending | approved | rejected
  note        text,
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at  timestamptz not null default now()
);
alter table public.verification_requests enable row level security;

create policy "verif req: owner insert" on public.verification_requests for insert
  with check (profile_id = auth.uid());
create policy "verif req: owner/admin read" on public.verification_requests for select
  using (profile_id = auth.uid() or public.is_admin());
create policy "verif req: admin update" on public.verification_requests for update
  using (public.is_admin());

-- Admin: approve a verification request and verify its company in one step.
create or replace function public.admin_review_verification(p_request uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_company uuid;
begin
  if not public.is_admin() then raise exception 'not authorized'; end if;
  update public.verification_requests
    set status = case when p_approve then 'approved' else 'rejected' end,
        note = p_note, reviewed_by = auth.uid(), reviewed_at = now()
    where id = p_request
    returning company_id into v_company;
  if p_approve and v_company is not null then
    perform public.admin_set_company_verified(v_company, true);
  end if;
end; $$;
