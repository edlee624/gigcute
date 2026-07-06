-- ATS batch 6 — 11 Greenhouse/Lever/Ashby company boards (dork-discovered, validated).
-- (jobgether excluded — it's a job aggregator, not a single company's board.)
insert into public.job_sources (platform, slug, company_name) values
 ('greenhouse','ziprecruiter','ZipRecruiter'),
 ('lever','contentsquare','Contentsquare'),
 ('lever','cyderes','Cyderes'),
 ('lever','remofirst','RemoFirst'),
 ('lever','sugarcrm','SugarCRM'),
 ('lever','workwave','WorkWave'),
 ('ashby','collective','Collective'),
 ('ashby','glade','Glade'),
 ('ashby','instructure','Instructure'),
 ('ashby','openrouter','OpenRouter'),
 ('ashby','superdial','SuperDial')
on conflict (platform, slug) do nothing;
