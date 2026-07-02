-- ============================================================================
-- Workday batch 2 — 45 enterprise tenants discovered via dorks + validated live.
-- Self-contained: re-applies the platform check + columns (idempotent) so it can
-- run standalone or after 0030. Safe to re-run (on conflict do nothing).
-- ============================================================================
alter table public.job_sources drop constraint if exists job_sources_platform_check;
alter table public.job_sources add constraint job_sources_platform_check
  check (platform in ('greenhouse','lever','ashby','workable','workday','taleo','icims'));
alter table public.job_sources add column if not exists datacenter text;
alter table public.job_sources add column if not exists site text;

insert into public.job_sources (platform, slug, company_name, datacenter, site) values
  ('workday','accenture','Accenture','wd103','AccentureCareers'),
  ('workday','alliantgroup','alliantgroup','wd1','alliantgroup'),
  ('workday','amgen','Amgen','wd1','careers'),
  ('workday','aritzia','Aritzia','wd3','External'),
  ('workday','astrazeneca','AstraZeneca','wd3','Careers'),
  ('workday','autodesk','Autodesk','wd1','Ext'),
  ('workday','bakerhughes','Baker Hughes','wd5','BakerHughes'),
  ('workday','bcbsnc','Blue Cross NC','wd5','bcbsnc'),
  ('workday','blackrock','BlackRock','wd1','BlackRock_Professional'),
  ('workday','broadridge','Broadridge','wd5','Careers'),
  ('workday','collegeboard','College Board','wd1','Careers'),
  ('workday','corebridgefinancial','Corebridge Financial','wd1','CorebridgeFinancial'),
  ('workday','csl','CSL','wd1','CSL_External'),
  ('workday','djeholdings','Edelman','wd5','edelman-careers-E200'),
  ('workday','ehealthinsurance','eHealth','wd5','EHI'),
  ('workday','emcins','EMC Insurance','wd5','emc_careers'),
  ('workday','epicorsoftware','Epicor','wd5','epicorjobs'),
  ('workday','guidehouse','Guidehouse','wd1','External'),
  ('workday','hbpublishing','Harvard Business Publishing','wd1','Careers'),
  ('workday','hyvee','Hy-Vee','wd1','MidwestHeritageCareers'),
  ('workday','labcorp','Labcorp','wd1','External'),
  ('workday','lseg','London Stock Exchange Group','wd3','Careers'),
  ('workday','manulife','Manulife','wd3','MFCJH_Jobs'),
  ('workday','medline','Medline','wd5','Medline'),
  ('workday','mgic','MGIC','wd5','MGIC'),
  ('workday','mourant','Mourant','wd103','mourantcareers'),
  ('workday','nextgen','NextGen Healthcare','wd5','nextgen_careers'),
  ('workday','parsons','Parsons','wd5','Search'),
  ('workday','pssigroup','PSSI','wd501','External_Careers'),
  ('workday','relx','RELX / LexisNexis','wd3','LexisNexisLegal'),
  ('workday','sggovterp','Singapore Public Service','wd102','PublicServiceCareers'),
  ('workday','sphera','Sphera','wd1','careers'),
  ('workday','statestreet','State Street','wd1','Global'),
  ('workday','strayer','Strategic Education','wd1','SEI'),
  ('workday','swbc','SWBC','wd1','Collections'),
  ('workday','thehartford','The Hartford','wd5','Careers_External'),
  ('workday','thomsonreuters','Thomson Reuters','wd5','External_Career_Site'),
  ('workday','tricon','Tricon Residential','wd3','tricon'),
  ('workday','uchicago','University of Chicago','wd5','External'),
  ('workday','utaustin','UT Austin','wd1','UTstaff'),
  ('workday','vantagedc','Vantage Data Centers','wd1','Vantage'),
  ('workday','visa','Visa','wd5','Visa'),
  ('workday','westernalliancebank','Western Alliance Bank','wd5','WAB'),
  ('workday','wk','Wolters Kluwer','wd3','External'),
  ('workday','workiva','Workiva','wd503','careers')
on conflict (platform, slug) do nothing;
