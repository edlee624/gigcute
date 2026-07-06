-- ATS batch 10 — 14 more company boards (dork-discovered, validated live).
insert into public.job_sources (platform, slug, company_name, datacenter, site) values
 ('greenhouse','censys','Censys',null,null),
 ('greenhouse','commercetools','commercetools',null,null),
 ('lever','aledade','Aledade',null,null),
 ('lever','loopreturns','Loop',null,null),
 ('lever','matchgroup','Match Group',null,null),
 ('lever','patchmypc','Patch My PC',null,null),
 ('lever','redoxengine','Redox',null,null),
 ('workday','bilh','Beth Israel Lahey Health','wd1','External'),
 ('workday','blueowl','Blue Owl','wd1','blueowl'),
 ('workday','flextronics','Flex','wd1','Careers'),
 ('workday','gehc','GE Healthcare','wd5','GEHC_ExternalSite'),
 ('workday','kone','KONE','wd3','Careers'),
 ('workday','magna','Magna','wd3','Magna'),
 ('workday','pciservices','PCI Pharma Services','wd1','External')
on conflict (platform, slug) do nothing;
