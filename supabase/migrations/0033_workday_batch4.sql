-- Workday batch 4 — 14 more enterprise tenants (dork-discovered, validated live).
-- Broad mode: dorked on generic titles (software engineer / account executive).
insert into public.job_sources (platform, slug, company_name, datacenter, site) values
 ('workday','adtran','ADTRAN','wd3','ADTRAN'),
 ('workday','arcticwolf','Arctic Wolf','wd1','External'),
 ('workday','cengage','Cengage','wd5','CengageNorthAmericaCareers'),
 ('workday','cmu','Carnegie Mellon','wd5','CMU'),
 ('workday','empower','Empower','wd12','empower'),
 ('workday','gapinc','Gap Inc','wd1','GAPINC'),
 ('workday','guidewire','Guidewire','wd5','external'),
 ('workday','hp','HP','wd5','ExternalCareerSite'),
 ('workday','infobip','Infobip','wd3','InfobipCareers'),
 ('workday','myworkdaycenter','MediaNews Group','wd5','MNG'),
 ('workday','nextracker','Nextracker','wd5','nextpower_careers'),
 ('workday','premierinc','Premier Inc','wd1','external_professional'),
 ('workday','stord','Stord','wd503','stord_external_career'),
 ('workday','workday','Workday','wd5','Workday')
on conflict (platform, slug) do nothing;
