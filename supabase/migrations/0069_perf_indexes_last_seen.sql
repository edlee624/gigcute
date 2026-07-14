-- ============================================================================
-- GigCute — performance: missing hot-path indexes + job freshness tracking.
--   * seeker_interest / recruiter_interest / invites all have composite PKs whose
--     leading column doesn't match the app's other lookup direction — every
--     posting-stats, candidate-signals, and invite-inbox query was a seq scan.
--   * The default board query (active, newest first) gets a matching partial
--     index; location filters get a trigram index (ILIKE '%x%').
--   * jobs.last_seen_at lets ingest reconcile against the source board and
--     deactivate ads that closed at the source (see ingest-jobs).
-- ============================================================================
create index if not exists seeker_interest_posting_idx  on public.seeker_interest (posting_id);
create index if not exists recruiter_interest_seeker_idx on public.recruiter_interest (seeker_id);
create index if not exists invites_seeker_idx            on public.invites (seeker_id);
create index if not exists jobs_active_posted_idx        on public.jobs (posted_at desc) where is_active;

create extension if not exists pg_trgm;
create index if not exists jobs_location_trgm_idx on public.jobs using gin (location gin_trgm_ops);

alter table public.jobs add column if not exists last_seen_at timestamptz not null default now();

-- Purge closed ads (deactivated by ingest reconciliation) after a 3-day grace.
select cron.schedule('purge-inactive-jobs', '30 3 * * *',
  $job$delete from public.jobs where not is_active and updated_at < now() - interval '3 days'$job$);
