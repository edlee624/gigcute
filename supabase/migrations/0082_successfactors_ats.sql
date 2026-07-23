-- Admit SAP SuccessFactors (Recruiting Marketing / Career Site Builder) as a
-- job_sources platform — the first of the enterprise "white-labeled" ATS tier
-- (SuccessFactors / Phenom / Eightfold) that live on each company's own domain
-- rather than a single shared ATS domain.
--
-- slug = the career-site host (e.g. 'jobs.ball.com', 'careers.cintas.com'); jobs
-- come from GET https://{slug}/job-feed.xml (RSS, Google-jobs schema) with the
-- posting date read from the job page's schema.org microdata. Ingested by
-- ingest-jobs' fromSuccessFactors and discovery/backfill.py.
alter table public.job_sources drop constraint if exists job_sources_platform_check;
alter table public.job_sources add constraint job_sources_platform_check
  check (platform in (
    'greenhouse','lever','ashby','workable','workday','taleo','icims',
    'smartrecruiters','recruitee','bamboohr','oraclecloud','successfactors'
  ));
