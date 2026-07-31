-- Structured US state (2-letter) on jobs, derived from the free-text location.
-- Only returns for US locations (state code in the US set, or a full US state name),
-- so it doubles as a US signal and powers accurate metro / state filtering without
-- the cross-state false positives of pure token matching ("Austin, MN" vs "Austin, TX").
create or replace function public.parse_us_state(loc text)
returns text language plpgsql immutable as $$
declare
  u text := upper(coalesce(loc, ''));
  l text := lower(coalesce(loc, ''));
  st text;
begin
  if l = '' then return null; end if;
  -- ", XX" 2-letter code, validated against the US state/territory set
  st := (regexp_match(u, ',\s*([A-Z]{2})(?:[,\s]|$)'))[1];
  if st is not null and st = any (array[
      'AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI','ID','IL','IN','IA','KS',
      'KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY',
      'NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV',
      'WI','WY','DC','PR','GU','VI']) then
    return st;
  end if;
  -- full state names (many ATS spell them out: "Costa Mesa, California, United States")
  if l ~ '\yalabama\y' then return 'AL'; end if;
  if l ~ '\yalaska\y' then return 'AK'; end if;
  if l ~ '\yarizona\y' then return 'AZ'; end if;
  if l ~ '\yarkansas\y' then return 'AR'; end if;
  if l ~ '\ycalifornia\y' then return 'CA'; end if;
  if l ~ '\ycolorado\y' then return 'CO'; end if;
  if l ~ '\yconnecticut\y' then return 'CT'; end if;
  if l ~ '\ydelaware\y' then return 'DE'; end if;
  if l ~ '\yflorida\y' then return 'FL'; end if;
  if l ~ '\ygeorgia\y' and l !~ 'tbilisi|republic of georgia' then return 'GA'; end if;
  if l ~ '\yhawaii\y' then return 'HI'; end if;
  if l ~ '\yidaho\y' then return 'ID'; end if;
  if l ~ '\yillinois\y' then return 'IL'; end if;
  if l ~ '\yindiana\y' then return 'IN'; end if;
  if l ~ '\yiowa\y' then return 'IA'; end if;
  if l ~ '\ykansas\y' then return 'KS'; end if;
  if l ~ '\ykentucky\y' then return 'KY'; end if;
  if l ~ '\ylouisiana\y' then return 'LA'; end if;
  if l ~ '\ymaine\y' then return 'ME'; end if;
  if l ~ '\ymaryland\y' then return 'MD'; end if;
  if l ~ '\ymassachusetts\y' then return 'MA'; end if;
  if l ~ '\ymichigan\y' then return 'MI'; end if;
  if l ~ '\yminnesota\y' then return 'MN'; end if;
  if l ~ '\ymississippi\y' then return 'MS'; end if;
  if l ~ '\ymissouri\y' then return 'MO'; end if;
  if l ~ '\ymontana\y' then return 'MT'; end if;
  if l ~ '\ynebraska\y' then return 'NE'; end if;
  if l ~ '\ynevada\y' then return 'NV'; end if;
  if l ~ 'new hampshire' then return 'NH'; end if;
  if l ~ 'new jersey' then return 'NJ'; end if;
  if l ~ 'new mexico' then return 'NM'; end if;
  if l ~ 'new york' then return 'NY'; end if;
  if l ~ 'north carolina' then return 'NC'; end if;
  if l ~ 'north dakota' then return 'ND'; end if;
  if l ~ '\yohio\y' then return 'OH'; end if;
  if l ~ '\yoklahoma\y' then return 'OK'; end if;
  if l ~ '\yoregon\y' then return 'OR'; end if;
  if l ~ 'pennsylvania' then return 'PA'; end if;
  if l ~ 'rhode island' then return 'RI'; end if;
  if l ~ 'south carolina' then return 'SC'; end if;
  if l ~ 'south dakota' then return 'SD'; end if;
  if l ~ '\ytennessee\y' then return 'TN'; end if;
  if l ~ '\ytexas\y' then return 'TX'; end if;
  if l ~ '\yutah\y' then return 'UT'; end if;
  if l ~ '\yvermont\y' then return 'VT'; end if;
  if l ~ '\yvirginia\y' and l !~ 'west virginia' then return 'VA'; end if;
  if l ~ 'west virginia' then return 'WV'; end if;
  if l ~ '\ywashington\y' and l !~ 'washington,?\s*d' then return 'WA'; end if;
  if l ~ '\ywisconsin\y' then return 'WI'; end if;
  if l ~ '\ywyoming\y' then return 'WY'; end if;
  return null;
end $$;

alter table public.jobs add column if not exists us_state text;

-- Extend the country trigger to also set us_state on every write.
create or replace function public.jobs_set_country() returns trigger
language plpgsql as $$
begin
  new.country  := public.parse_country(new.location);
  new.us_state := public.parse_us_state(new.location);
  return new;
end $$;

create index if not exists jobs_us_state_idx on public.jobs (us_state);
