-- ============================================================================
-- Workday batch 3 — 41 more enterprise tenants (dork-discovered, validated live).
-- Self-contained + idempotent. Titles dorked: director/transformation, principal
-- PM, head of analytics, senior manager analytics, CX manager, VP analytics.
-- ============================================================================
alter table public.job_sources drop constraint if exists job_sources_platform_check;
alter table public.job_sources add constraint job_sources_platform_check
  check (platform in ('greenhouse','lever','ashby','workable','workday','taleo','icims'));
alter table public.job_sources add column if not exists datacenter text;
alter table public.job_sources add column if not exists site text;

insert into public.job_sources (platform, slug, company_name, datacenter, site) values
  ('workday','hillenbrand','Hillenbrand','wd3','Global'),
  ('workday','zelis','Zelis','wd1','ZelisCareers'),
  ('workday','usaa','USAA','wd1','USAAJOBSWD'),
  ('workday','xcelenergy','Xcel Energy','wd1','External'),
  ('workday','lego','LEGO','wd103','LEGO_External'),
  ('workday','avisbudget','Avis Budget Group','wd1','ABG_Careers'),
  ('workday','worldwide','Worldwide Clinical Trials','wd1','External'),
  ('workday','jll','JLL','wd1','jllcareers'),
  ('workday','zillow','Zillow','wd5','Zillow_Group_External'),
  ('workday','capgroup','Capital Group','wd1','capitalgroupcareers'),
  ('workday','fortune','Fortune Media','wd108','Fortune'),
  ('workday','bonterra','Bonterra','wd1','bonterratech'),
  ('workday','toppanmerrill','Toppan Merrill','wd5','Toppan_Merrill'),
  ('workday','geico','GEICO','wd1','External'),
  ('workday','condenast','Conde Nast','wd5','CondeCareers'),
  ('workday','paypal','PayPal','wd1','jobs'),
  ('workday','evonik','Evonik','wd3','External_Careers'),
  ('workday','pfizer','Pfizer','wd1','PfizerCareers'),
  ('workday','biibhr','Biogen','wd3','external'),
  ('workday','td','TD Bank','wd3','td_bank_careers'),
  ('workday','taxwell','Taxwell','wd1','taxwell'),
  ('workday','zoetis','Zoetis','wd5','zoetis'),
  ('workday','pae','Amentum','wd1','amentum_careers'),
  ('workday','vanguard','Vanguard','wd5','vanguard_external'),
  ('workday','phreesia','Phreesia','wd1','PhreesiaCanada'),
  ('workday','coke','Coca-Cola','wd1','coca-cola-careers'),
  ('workday','birch','Fusion Connect','wd1','fusioncareers'),
  ('workday','alliancedata','Bread Financial','wd5','breadfinancial_US'),
  ('workday','aquafinance','Aqua Finance','wd12','aqua_finance'),
  ('workday','kith','Kith','wd1','Kith_External_Careers'),
  ('workday','brambles','Brambles','wd5','Brambles_Careers'),
  ('workday','fivebelow','Five Below','wd1','fivebelowcareers'),
  ('workday','streamlinehealthcare','Streamline Healthcare','wd501','Streamline_Healthcare_External_Careers'),
  ('workday','assetmark','AssetMark','wd5','AssetMark_Careers'),
  ('workday','oumedicine','OU Health','wd5','OUHealthCareers'),
  ('workday','3m','3M','wd1','Search'),
  ('workday','akumincorp','Akumin','wd5','akumincareers'),
  ('workday','gartner','Gartner','wd5','EXT'),
  ('workday','scholastic','Scholastic','wd5','External'),
  ('workday','ms','Morgan Stanley','wd5','External'),
  ('workday','mastercard','Mastercard','wd1','corporatecareers')
on conflict (platform, slug) do nothing;
