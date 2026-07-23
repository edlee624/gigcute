-- Admit Oracle Cloud Recruiting (Fusion HCM / ORC — the Taleo successor) as a
-- job_sources platform. Boards live at {pod}.oraclecloud.com and are addressed by
-- a pod + a CandidateExperience site code, so (like Workday) they need the extra
-- columns: slug = pod (e.g. "ejgl.fa.ap1"), site = site code (e.g. "CX_1").
-- datacenter is unused for this platform.
--
-- Ingested by ingest-jobs' fromOracleCloud (2-hop: list -> detail via
-- finder=ById) and discovery/backfill.py. Part of the push past 20k companies.
alter table public.job_sources drop constraint if exists job_sources_platform_check;
alter table public.job_sources add constraint job_sources_platform_check
  check (platform in (
    'greenhouse','lever','ashby','workable','workday','taleo','icims',
    'smartrecruiters','recruitee','bamboohr','oraclecloud'
  ));
