-- ============================================================================
-- GigCute — store the seeker's uploaded resume
-- The file goes to the public 'media' Storage bucket (under resumes/<uid>/...)
-- and its public URL is kept here so the profile page can offer a download link.
-- ============================================================================
alter table public.seeker_profiles
  add column if not exists resume_url text;
