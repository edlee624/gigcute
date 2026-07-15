-- GigCute — seeker: desired job titles + target salary range (registration).
alter table public.seeker_profiles
  add column if not exists desired_titles     text[] default '{}',
  add column if not exists desired_salary_min int,
  add column if not exists desired_salary_max int;