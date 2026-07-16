-- Widen the job_sources platform check to admit the clean-JSON ATS tier:
-- SmartRecruiters, Recruitee, BambooHR (Workable was already allowed). These are
-- direct per-company boards with public JSON APIs, ingested by the ingest-jobs
-- edge function (fromSmartRecruiters / fromRecruitee / fromBambooHR) and the local
-- discovery/backfill.py sweep. Part of the push from ~10.5k to 20k companies.
alter table public.job_sources drop constraint if exists job_sources_platform_check;
alter table public.job_sources add constraint job_sources_platform_check
  check (platform in (
    'greenhouse','lever','ashby','workable','workday','taleo','icims',
    'smartrecruiters','recruitee','bamboohr'
  ));
