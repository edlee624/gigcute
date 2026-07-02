-- ============================================================================
-- Workday support for job_sources.
-- A Workday board needs tenant (slug) + datacenter + site to build its API URL:
--   https://{slug}.{datacenter}.myworkdayjobs.com/wday/cxs/{slug}/{site}/jobs
-- Also widen the platform check for future enterprise sources (taleo, icims).
-- ============================================================================
alter table public.job_sources drop constraint if exists job_sources_platform_check;
alter table public.job_sources add constraint job_sources_platform_check
  check (platform in ('greenhouse','lever','ashby','workable','workday','taleo','icims'));

alter table public.job_sources add column if not exists datacenter text;
alter table public.job_sources add column if not exists site text;

-- Seed the Workday tenants discovered + validated (all confirmed live, >0 jobs).
insert into public.job_sources (platform, slug, company_name, datacenter, site) values
  ('workday','cisco','Cisco','wd5','Cisco_Careers'),
  ('workday','imf','International Monetary Fund','wd5','IMF'),
  ('workday','blackstone','Blackstone','wd1','Blackstone_Careers'),
  ('workday','baincapital','Bain Capital','wd1','External_Public'),
  ('workday','troweprice','T. Rowe Price','wd5','TRowePrice'),
  ('workday','davita','DaVita','wd1','dkc_external'),
  ('workday','salesforce','Salesforce','wd12','External_Career_Site'),
  ('workday','barclays','Barclays','wd3','External_Career_Site_Barclays'),
  ('workday','bristolmyerssquibb','Bristol Myers Squibb','wd5','BMS'),
  ('workday','countryfinancial','COUNTRY Financial','wd5','COUNTRYCorporateExternal'),
  ('workday','gsk','GSK','wd5','GSKCareers'),
  ('workday','pnc','PNC','wd5','External'),
  ('workday','guidehouse','Guidehouse','wd1','External'),
  ('workday','broadridge','Broadridge','wd5','Careers'),
  ('workday','wisconsin','University of Wisconsin','wd1','UW_Madison'),
  ('workday','communitybrands','Community Brands','wd1','momentive_external_careers'),
  ('workday','graco','Graco','wd501','Graco_Careers'),
  ('workday','servicetitan','ServiceTitan','wd1','ServiceTitan'),
  ('workday','thomsonreuters','Thomson Reuters','wd5','External_Career_Site'),
  ('workday','visa','Visa','wd5','Visa'),
  ('workday','zendesk','Zendesk','wd1','zendesk'),
  ('workday','univision','TelevisaUnivision','wd1','External'),
  ('workday','trimble','Trimble','wd1','TrimbleCareers'),
  ('workday','alegeus','Alegeus','wd1','Alegeus_External_Careers')
on conflict (platform, slug) do nothing;
