-- ============================================================================
-- GigCute — make keyword search on the job board survive the feed size.
--
-- Symptom: jobs.list({ q: 'developer' }) timed out. The board is a core feature
-- and it was falling over on a plain keyword search.
--
-- Cause: the client search builds
--     or(title.ilike.%q%, company.ilike.%q%, location.ilike.%q%)
-- and PostgREST pairs it with count:'exact'. A leading-wildcard ILIKE cannot use
-- a b-tree index, so each arm needs its own trigram index. title and location
-- had one (jobs_title_trgm_idx, jobs_location_trgm_idx); COMPANY DID NOT — so
-- every search seq-scanned the whole feed, and the exact count paid that cost a
-- second time just to produce a total.
--
-- Measured on production (~233k rows, count=exact, correct totals throughout):
--   count over the OR-chain      6720 ms  ->   ~780 ms
--   full paged search request    1801 ms  ->   ~375 ms
--   cold uncommon terms (welder, phlebotomist, kubernetes, actuary, sommelier)
--                                        0.4 - 1.6 s, no timeouts
--
-- NOTE: pg_trgm is installed in `public` on this project, not `extensions`.
-- If you add a column to the search OR-chain, it needs a trigram index too, or
-- the seq scan comes straight back.
-- ============================================================================

create index if not exists jobs_company_trgm_idx
  on public.jobs using gin (company public.gin_trgm_ops);

analyze public.jobs;
