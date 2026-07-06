-- ATS batch 9 — 21 more company boards (dork-discovered, validated live).
insert into public.job_sources (platform, slug, company_name, datacenter, site) values
 ('greenhouse','axios','Axios',null,null),
 ('greenhouse','fleetio','Fleetio',null,null),
 ('greenhouse','forbes','Forbes',null,null),
 ('greenhouse','fundraiseup','Fundraise Up',null,null),
 ('greenhouse','myfitnesspal','MyFitnessPal',null,null),
 ('greenhouse','similarweb','Similarweb',null,null),
 ('ashby','avoca','Avoca',null,null),
 ('ashby','civilgrid','CivilGrid',null,null),
 ('ashby','creatoriq','CreatorIQ',null,null),
 ('ashby','dash0','Dash0',null,null),
 ('ashby','inclined','Inclined',null,null),
 ('ashby','intellistack','Intellistack',null,null),
 ('ashby','sona','Sona',null,null),
 ('workday','msiexpress','MSI Express','wd5','MSI_Express_External_Careers'),
 ('workday','flir','Teledyne FLIR','wd1','flircareers'),
 ('workday','albemarle','Albemarle','wd5','KetjenExternal'),
 ('workday','creationtech','Creation Technologies','wd1','Creation'),
 ('workday','mpc','Marathon Petroleum','wd1','MPCCareers'),
 ('workday','gphealth','Great Plains Health','wd5','GPH'),
 ('workday','pg','Procter & Gamble','wd5','1000'),
 ('workday','oceanspray','Ocean Spray','wd5','OceanSprayJobs')
on conflict (platform, slug) do nothing;
