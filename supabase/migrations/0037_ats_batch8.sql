-- ATS batch 8 — 15 more company boards (dork-discovered, validated live).
insert into public.job_sources (platform, slug, company_name, datacenter, site) values
 ('greenhouse','embrace','Embrace',null,null),
 ('greenhouse','stockx','StockX',null,null),
 ('greenhouse','techstars57','Techstars',null,null),
 ('lever','articulate','Articulate',null,null),
 ('lever','pointclickcare','PointClickCare',null,null),
 ('lever','sonatype','Sonatype',null,null),
 ('lever','truv','Truv',null,null),
 ('workday','worldpay','Worldpay','wd5','Worldpay_External_Careers_Site'),
 ('workday','amcor','Amcor','wd5','Amcor_External_Career_Site'),
 ('workday','asmglobal','ASM Global','wd1','careers'),
 ('workday','gables','Gables Residential','wd5','Gables_Careers'),
 ('workday','umb','UMB','wd1','UMBExternal'),
 ('workday','clorox','Clorox','wd1','Clorox'),
 ('workday','nreca','NRECA','wd1','External'),
 ('workday','guardianlife','Guardian Life','wd5','Guardian-Life-Careers')
on conflict (platform, slug) do nothing;
