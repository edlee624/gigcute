-- cron_active gates which companies the frequent Supabase cron scans. The daily
-- local backfill (backfill.py --all) is the primary full-coverage ingestion; it
-- recomputes cron_active to false for boards that currently yield zero jobs, so the
-- light cron (2-day intake) stops wasting fetches/memory on ~thousands of empty
-- boards (which was causing 546 worker-limit crashes). Full coverage of the skipped
-- boards still comes from the daily --all. Default true so new boards are scanned
-- until the next daily sweep establishes their yield.
alter table public.job_sources add column if not exists cron_active boolean not null default true;
create index if not exists job_sources_cron_active_idx on public.job_sources (cron_active) where cron_active;
