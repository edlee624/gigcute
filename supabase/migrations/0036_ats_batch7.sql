-- ATS batch 7 — 20 more company boards (dork-discovered, validated live).
-- 8 Greenhouse, 4 Ashby, 8 Workday. Broad mode.
insert into public.job_sources (platform, slug, company_name, datacenter, site) values
 ('greenhouse','arcadiacareers','Arcadia',null,null),
 ('greenhouse','augury','Augury',null,null),
 ('greenhouse','humanagency','Human Agency',null,null),
 ('greenhouse','impact','Impact.com',null,null),
 ('greenhouse','mewssystems','Mews',null,null),
 ('greenhouse','snapmobileinc','Snap! Mobile',null,null),
 ('greenhouse','tbwachiatday','TBWA Chiat Day',null,null),
 ('greenhouse','yipitdata','YipitData',null,null),
 ('ashby','assembledhq','Assembled',null,null),
 ('ashby','intrinsic-safety','Variance',null,null),
 ('ashby','klue','Klue',null,null),
 ('ashby','novig','Novig',null,null),
 ('workday','onemagnify','OneMagnify','wd5','OneMagnify_Careers'),
 ('workday','leidos','Leidos','wd5','External'),
 ('workday','deluxe','Deluxe','wd5','USA_CAN'),
 ('workday','elevancehealth','Elevance Health','wd1','ANT'),
 ('workday','nasdaq','Nasdaq','wd1','Global_External_Site'),
 ('workday','waystar','Waystar','wd1','Waystar'),
 ('workday','dealertire','Dealer Tire','wd5','DealerTireLLC-Careers'),
 ('workday','hcmportal','UPS','wd5','Search')
on conflict (platform, slug) do nothing;
