-- Workday batch 5 — 22 more enterprise tenants (dork-discovered, validated live).
-- Broad mode: dorked on generic titles (financial analyst / project manager / operations manager).
insert into public.job_sources (platform, slug, company_name, datacenter, site) values
 ('workday','bah','Booz Allen Hamilton','wd1','BAH_Jobs'),
 ('workday','huron','Huron','wd1','huroncareers'),
 ('workday','micron','Micron','wd1','External'),
 ('workday','uline','Uline','wd1','Uline_Careers'),
 ('workday','clarioclinical','Clario','wd1','clarioclinical_careers'),
 ('workday','bwe','BWE','wd12','BWECareers'),
 ('workday','stewart','Stewart','wd1','External'),
 ('workday','clark','Clark Construction','wd503','ClarkExternal'),
 ('workday','uw','University of Washington','wd5','UWHires'),
 ('workday','spscommerce','SPS Commerce','wd108','SPS'),
 ('workday','evs','EVS','wd108','evsengineeringcareers'),
 ('workday','rsm','RSM','wd1','RSMCareers'),
 ('workday','sciensbuildingsolutions','Sciens Building Solutions','wd108','sciens_external_careers'),
 ('workday','pgatoursuperstore','PGA Tour Superstore','wd12','PGAT_SS'),
 ('workday','hexcel','Hexcel','wd5','HexcelCareers'),
 ('workday','sbmmanagement','SBM Management','wd108','SBM'),
 ('workday','pennmutual','Penn Mutual','wd1','_penn-careers'),
 ('workday','wsu','Washington State University','wd5','WSU_Jobs'),
 ('workday','integer','Integer','wd1','External'),
 ('workday','walmart','Walmart','wd504','WalmartExternal'),
 ('workday','veritiv','Veritiv','wd5','VeritivCareers'),
 ('workday','transportationinsight','Transportation Insight','wd1','TI_NTG_External_Careers')
on conflict (platform, slug) do nothing;
