# GigCute backend setup (Supabase)

This turns the prototype into a real app with accounts and a database. The
frontend stays a static site on Vercel and talks to **Supabase** (managed
Postgres + Auth + Storage). Supabase stores passwords and PII securely so you
aren't rolling your own auth.

> **What only you can do:** creating the Supabase project, entering any billing
> details, and setting secrets are account actions I can't do for you. Follow
> the steps below; the code in this repo is ready the moment you finish.

---

## 1. Create the Supabase project

1. Go to <https://supabase.com> and sign up (GitHub login is easiest).
2. **New project** → name it `gigcute`, pick a region near your users, set a
   strong database password (save it in your password manager).
3. Wait ~2 minutes for it to provision.

## 2. Run the database migrations

The schema lives in `supabase/migrations/`. Two ways to apply it:

**Option A — SQL editor (no tooling):**
1. In the Supabase dashboard → **SQL Editor** → **New query**.
2. Paste the full contents of `supabase/migrations/0001_init.sql`, run it.
3. New query → paste `supabase/migrations/0002_reference_data.sql`, run it.

**Option B — Supabase CLI (repeatable, recommended once you're iterating):**
```bash
npm install -g supabase
supabase login
supabase link --project-ref YOUR-PROJECT-REF
supabase db push        # applies everything in supabase/migrations
```

Verify: **Table Editor** should show `profiles`, `seeker_profiles`, `companies`,
`postings`, `screening_questions`, `eeo_responses`, etc., and `screening_templates`
should have 22 rows.

## 3. Wire the frontend to your project

1. Dashboard → **Project Settings → API**. Copy the **Project URL** and the
   **anon / public** key. (Do **not** use the `service_role` key in the frontend.)
2. In `public/`, copy `config.example.js` to `config.js` and paste your values:
   ```js
   window.GIGCUTE_CONFIG = {
     SUPABASE_URL: 'https://abcd1234.supabase.co',
     SUPABASE_ANON_KEY: 'eyJ...your anon key...',
   };
   ```
   `config.js` is gitignored. For the Vercel deploy, add the same two values as
   build-time and generate `config.js` in your build, **or** simply commit a
   `config.js` with the anon key (it's a public value, protected by RLS) — your
   call. Until `config.js` exists the app runs in demo/in-memory mode and
   `window.GigCuteAPI.enabled` is `false`.

## 4. Configure Auth

1. **Authentication → Providers → Email**: keep enabled. For launch, leave
   "Confirm email" **on** so addresses are verified.
2. **Google OAuth** (the "Continue with Google" buttons): Providers → Google →
   add your Google Cloud OAuth client ID/secret, and add your site URL to the
   redirect allow-list.
3. **Authentication → URL Configuration**: set **Site URL** to your production
   domain (e.g. `https://gigcute.com`) and add `http://localhost:3000` for local
   testing.

## 5. Deploy

The static frontend already deploys to Vercel from `public/` (see root README).
Push to `main`, Vercel redeploys. Make sure `public/config.js` is present in the
deploy (committed, or generated at build time).

---

## How the data model is secured

The browser holds only the **anon key**, so **Row Level Security (RLS)** is the
real security boundary — every table has it enabled with explicit policies
(`supabase/migrations/0001_init.sql`). Highlights:

- A `profiles` row is created automatically on signup by a trigger; `role`
  (`seeker`/`recruiter`) and name come from the signup metadata.
- Seekers can only edit their own profile/work history/answers; recruiters can
  read visible candidate profiles.
- Company members manage their company and its postings; everyone signed in can
  read **active** postings.
- Screening-question **tier limits are enforced in the database** (Basic 0,
  Boost 3, Featured 10) by a trigger — not just in the UI.

### EEO / DE&I data is firewalled (important, legally)

Voluntary self-identification answers live in `eeo_responses` with **no recruiter
read policy at all** — recruiters cannot query individual rows. Aggregate
reporting is only available through the `eeo_aggregate()` function, which
**suppresses small cells** (groups under 5) to prevent re-identification. The
schema also forces voluntary questions to be non-essential so they can never feed
the auto-reject filter. Before real users hit this, have your privacy policy and
this handling reviewed by counsel.

---

## Frontend wiring status & plan

The API layer (`public/js/gigcute-api.js`, exposed as `window.GigCuteAPI`) is
complete and covers auth, profiles, companies, postings, screening, interest,
invites, EEO, reference data, and reports. The app's existing inline script still
uses **in-memory mock data**; migrating each flow to call `GigCuteAPI` is the
remaining work, sequenced so you can open registration first:

1. **Auth** — wire the seeker/recruiter register + login + Google + forgot-password
   buttons to `GigCuteAPI.auth.*`; gate the dashboards on a real session.
2. **Profiles & companies** — persist seeker onboarding and company registration
   (`seeker.upsert`, `companies.create`).
3. **Postings** — publish/edit write to `postings` + `screening_questions`; the
   recruiter dashboard and candidate job list read from the DB.
4. **Interest, invites, matches** — replace the mock arrays with
   `interest.*` / `invites.*` / the `matches` view.
5. **Reports & analytics** — `reports.file`, `events`.

Each step is independently shippable behind the `GigCuteAPI.enabled` flag, so the
demo keeps working until a flow is fully migrated.
