-- ATS batch 11 — 21 more company boards (dork-discovered, validated live).
insert into public.job_sources (platform, slug, company_name, datacenter, site) values
 ('greenhouse','cbinsights','CB Insights',null,null),
 ('greenhouse','definitivehc','Definitive Healthcare',null,null),
 ('greenhouse','doordashusa','DoorDash',null,null),
 ('greenhouse','mntn','MNTN',null,null),
 ('greenhouse','paveakatroveinformationtechnologies','Pave',null,null),
 ('greenhouse','tenableinc','Tenable',null,null),
 ('ashby','meridianlink','MeridianLink',null,null),
 ('ashby','oscilar','Oscilar',null,null),
 ('ashby','quartermaster','Quartermaster',null,null),
 ('ashby','workwhilejobs','WorkWhile',null,null),
 ('ashby','zefr','Zefr',null,null),
 ('lever','outreach','Outreach',null,null),
 ('workday','asuep','ASU Enterprise Partners','wd5','ASUEP'),
 ('workday','bgfoods','B&G Foods','wd1','BG_Foods_Careers'),
 ('workday','choicehotels','Choice Hotels','wd5','External'),
 ('workday','livingspaces','Living Spaces','wd5','LS'),
 ('workday','orionadvisor','Orion','wd1','Orion_Careers'),
 ('workday','pacs','PACS Group','wd108','pacs'),
 ('workday','peoplecorporation','People Corporation','wd10','People_Corporation'),
 ('workday','rochester','University of Rochester','wd5','UR_Staff'),
 ('workday','tsc','Tractor Supply','wd12','TSC-Careers')
on conflict (platform, slug) do nothing;
