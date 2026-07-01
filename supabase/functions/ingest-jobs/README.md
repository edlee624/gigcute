# ingest-jobs

Pulls job listings from public job APIs and upserts them into `public.jobs`
(deduped by `source` + `external_id`). Designed to run on a schedule.

Sources:
- **arbeitnow** — free, no key. Works immediately.
- **adzuna** — broad coverage across industries/countries. Needs a free
  `app_id` + `app_key` from https://developer.adzuna.com/ . Disabled until the
  secrets are set.

## 1. Apply the table migration
Run `supabase/migrations/0024_jobs.sql` in the Supabase SQL editor.

## 2. Deploy the function
**Option A — Dashboard (no CLI):** Edge Functions → Create function → name it
`ingest-jobs` → paste `index.ts` → Deploy. Then in the function's settings turn
**"Verify JWT" OFF**.

**Option B — CLI:** `supabase functions deploy ingest-jobs` (config.toml already
sets `verify_jwt = false`).

## 3. Set secrets
Project Settings → Edge Functions → Secrets (or `supabase secrets set ...`):
- `CRON_SECRET` — any long random string (required).
- `ADZUNA_APP_ID`, `ADZUNA_APP_KEY` — optional, to enable Adzuna.
- `ADZUNA_COUNTRY` (default `us`), `ADZUNA_PAGES` (default `2`) — optional.

Adzuna targeting (optional — narrows results to a person's fit + geography):
- `ADZUNA_WHAT` — keyword query, e.g. `customer experience analytics` (default).
- `ADZUNA_WHERE` — comma-separated location anchors, e.g. `New York,Newark,Stamford` (default `New York`).
- `ADZUNA_DISTANCE_KM` — radius around each anchor (default `120`, ~covers NY/NJ/CT metro).
Adzuna runs one pass per `WHERE` anchor plus a US-wide remote-only pass.

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are provided automatically.

## 4. Test it once
```bash
curl -X POST "https://<PROJECT_REF>.supabase.co/functions/v1/ingest-jobs" \
  -H "x-cron-secret: <CRON_SECRET>"
```
Returns a per-source `{ fetched, upserted }` report. Then in SQL:
`select source, count(*) from public.jobs group by 1;`

## 5. Schedule it (hourly)
In the Supabase SQL editor:
```sql
create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule('ingest-jobs-hourly', '17 * * * *', $$
  select net.http_post(
    url     := 'https://<PROJECT_REF>.supabase.co/functions/v1/ingest-jobs',
    headers := jsonb_build_object('content-type','application/json','x-cron-secret','<CRON_SECRET>'),
    body    := '{}'::jsonb
  );
$$);
```
(Replace `<PROJECT_REF>` and `<CRON_SECRET>`. Unschedule with
`select cron.unschedule('ingest-jobs-hourly');`.)
