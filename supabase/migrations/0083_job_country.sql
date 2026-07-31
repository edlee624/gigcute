create or replace function public.parse_country(loc text)
returns text language plpgsql immutable as $$
declare
  l  text := lower(coalesce(loc, ''));
  u  text := upper(coalesce(loc, ''));
  st text;
begin
  -- empty, or the un-flattened location-object bug ({'country': None, ...})
  if l = '' or l like '%''country'':%' or l like '%"country":%' then
    return null;
  end if;

  -- 1) explicit US signals (multi-word name, or USA/US as a standalone token)
  if l ~ 'united states|\yu\.?s\.?a\y|\yusa\y' then return 'US'; end if;
  if l ~ 'united kingdom|\yengland\y|\yscotland\y|\ywales\y|great britain' then return 'GB'; end if;
  if l ~ 'united arab emirates|\ydubai\y|abu dhabi' then return 'AE'; end if;

  -- 2) ", XX" 2-letter region code -> US state or Canadian province
  st := (regexp_match(u, ',\s*([A-Z]{2})(?:[,\s]|$)'))[1];
  if st is not null then
    if st = any (array['AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI','ID','IL','IN','IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY','DC','PR','GU','VI']) then
      return 'US';
    elsif st = any (array['ON','BC','QC','AB','MB','SK','NS','NB','NL','PE','NT','YT','NU']) then
      return 'CA';
    end if;
  end if;

  -- 3) explicit country-name keywords
  if l ~ '\ycanada\y'          then return 'CA'; end if;
  if l ~ '\yindia\y'           then return 'IN'; end if;
  if l ~ '\ysingapore\y'       then return 'SG'; end if;
  if l ~ 'south korea|\yseoul\y' then return 'KR'; end if;
  if l ~ '\yireland\y'         then return 'IE'; end if;
  if l ~ '\yfrance\y'          then return 'FR'; end if;
  if l ~ 'germany|deutschland' then return 'DE'; end if;
  if l ~ '\yspain\y|espa'      then return 'ES'; end if;
  if l ~ '\yitaly\y|italia'    then return 'IT'; end if;
  if l ~ 'netherlands|holland' then return 'NL'; end if;
  if l ~ '\ypoland\y'          then return 'PL'; end if;
  if l ~ 'philippines'         then return 'PH'; end if;
  if l ~ '\yjapan\y'           then return 'JP'; end if;
  if l ~ '\ychina\y|shanghai|beijing|shenzhen' then return 'CN'; end if;
  if l ~ '\ybrazil\y|brasil'   then return 'BR'; end if;
  if l ~ '\ymexico\y|méxico'   then return 'MX'; end if;
  if l ~ 'australia'           then return 'AU'; end if;
  if l ~ 'new zealand'         then return 'NZ'; end if;
  if l ~ 'switzerland|schweiz' then return 'CH'; end if;
  if l ~ '\ysweden\y'          then return 'SE'; end if;
  if l ~ '\ynorway\y'          then return 'NO'; end if;
  if l ~ 'denmark'             then return 'DK'; end if;
  if l ~ 'finland'             then return 'FI'; end if;
  if l ~ 'belgium'             then return 'BE'; end if;
  if l ~ 'portugal'            then return 'PT'; end if;
  if l ~ '\yaustria\y'         then return 'AT'; end if;
  if l ~ '\yisrael\y'          then return 'IL'; end if;
  if l ~ 'south africa'        then return 'ZA'; end if;
  if l ~ 'hong kong'           then return 'HK'; end if;
  if l ~ 'malaysia'            then return 'MY'; end if;
  if l ~ 'indonesia'           then return 'ID'; end if;
  if l ~ '\yvietnam\y'         then return 'VN'; end if;
  if l ~ '\ythailand\y'        then return 'TH'; end if;
  if l ~ 'romania'             then return 'RO'; end if;
  if l ~ '\yczech'             then return 'CZ'; end if;
  if l ~ '\yturkey\y|türkiye'  then return 'TR'; end if;
  if l ~ '\yegypt\y'           then return 'EG'; end if;
  if l ~ 'argentina'           then return 'AR'; end if;
  if l ~ '\ychile\y'           then return 'CL'; end if;
  if l ~ 'colombia'            then return 'CO'; end if;
  if l ~ 'costa rica'          then return 'CR'; end if;

  -- 4) US ZIP code (no foreign signal matched above)
  if loc ~ '\y\d{5}(-\d{4})?\y' then return 'US'; end if;

  -- 5) standalone "US" token (e.g. "US Remote", "Remote - US") — after foreign checks
  if l ~ '\yus\y' then return 'US'; end if;

  -- 6) bare US metros/cities (no state code / country present)
  if l ~ '\y(new york city|new york|nyc|brooklyn|manhattan|san francisco|bay area|silicon valley|los angeles|chicago|boston|seattle|austin|atlanta|denver|dallas|houston|miami|washington d\.?c|philadelphia|phoenix|san diego|san jose|portland|nashville|charlotte|minneapolis|detroit|pittsburgh|cincinnati|cleveland|columbus|kansas city|salt lake|las vegas|sacramento|san antonio|indianapolis|milwaukee|raleigh|tampa|orlando|st\.? louis|hawthorne)\y' then
    return 'US';
  end if;

  -- 7) bare foreign cities
  if l ~ '\ylondon\y|manchester|edinburgh|\ybristol\y|\yleeds\y|glasgow' then return 'GB'; end if;
  if l ~ 'bengaluru|bangalore|mumbai|\ypune\y|hyderabad|chennai|gurgaon|gurugram|noida|new delhi|kolkata' then return 'IN'; end if;
  if l ~ '\yparis\y|\ylyon\y'   then return 'FR'; end if;
  if l ~ '\yberlin\y|munich|münchen|hamburg|frankfurt' then return 'DE'; end if;
  if l ~ '\ytoronto\y|vancouver|montreal|montréal|ottawa|calgary' then return 'CA'; end if;
  if l ~ '\ydublin\y'          then return 'IE'; end if;
  if l ~ 'amsterdam'           then return 'NL'; end if;
  if l ~ '\ymadrid\y|barcelona' then return 'ES'; end if;
  if l ~ '\ymilan\y|\yrome\y|\ymilano\y' then return 'IT'; end if;
  if l ~ '\ysydney\y|melbourne|brisbane|\yperth\y' then return 'AU'; end if;
  if l ~ '\ytokyo\y'           then return 'JP'; end if;
  if l ~ 'são paulo|sao paulo' then return 'BR'; end if;

  return null;  -- unknown
end $$;

-- Structured country on jobs, derived from the free-text location by parse_country().
-- Plain column + trigger (NOT a generated column): the parser is regex-heavy, so a
-- single-DDL rewrite of the whole table times out; existing rows are backfilled in
-- batches out-of-band. The trigger keeps country fresh on every insert / location
-- change, so no ingestion code (edge function / backfill.py) needs to change.
alter table public.jobs add column if not exists country text;

create or replace function public.jobs_set_country() returns trigger
language plpgsql as $$
begin
  new.country := public.parse_country(new.location);
  return new;
end $$;

drop trigger if exists trg_jobs_set_country on public.jobs;
create trigger trg_jobs_set_country
  before insert or update of location on public.jobs
  for each row execute function public.jobs_set_country();

create index if not exists jobs_country_idx on public.jobs (country);
