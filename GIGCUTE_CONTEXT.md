# GigCute — Project Context (handoff)

Paste this into a new chat to bring the assistant up to speed. Last updated 2026-06-29.

## What GigCute is
A "more than a résumé" platform for **job seekers**. Instead of bullet points, a seeker
answers **prompts** (in their own voice) that show how they think, plus work history,
portfolio/projects, education, and certifications. Each seeker gets a shareable public
**profile** at a short URL, a **QR code**, and a printable **interview cheat sheet**.

Tagline: *"Showcase more of who you are with a GigCute Profile."*

The recruiter side ("GigCute-Recruit") is **coming soon** — a teaser + Google Form only.
GigCute Search (the seeker-discovery side) is gated behind a "Maybe coming soon" overlay.

## Repo & workflow
- **Local repo:** `C:\Users\edios\Documents\GitHub\gigcute` (edit here — do NOT use any Drive copy).
- **Branches:** `main` = live app. `futurestate` = full app for a later release.
- **Deploy:** Vercel. Push to `main` → production deploy. `vercel.json` uses legacy
  builds+routes with an SPA catch-all.
- **Commits:** the user prefers ONE end-of-day commit, not per-change commits — but in
  practice we've been committing per finished feature. Confirm before committing if unsure.
- **Shell:** Windows PowerShell. Multi-line/quoted commit messages break here — write the
  message to `gc_msg.txt` and `git commit -F gc_msg.txt`, then delete it. The `git :`
  stderr lines on push are normal progress, not errors.
- **Git author:** edlee624. **Contact email used in-app:** gigcutesite@gmail.com.

## Architecture
- **`public/index.html`** — the entire app, ONE file (~6k lines): inline `<style>`,
  markup, and a single `<script>` IIFE. Inline `onclick="X()"` requires `window.X = X`.
- **`public/js/gigcute-api.js`** — the Supabase API layer (ES module, `window.GigCuteAPI`).
  Self-hosted Supabase client via `window.supabase` (no esm.sh). `GigCuteAPI.enabled` is
  false unless `public/config.js` exists → app runs in demo/in-memory mode.
- **Vendored libs:** `public/js/vendor/supabase.umd.js`, `public/js/vendor/qrcode.min.js`
  (global `qrcode`). **Script tags use ABSOLUTE paths** (`/config.js`, `/js/...`, `/logo.png`)
  — relative paths broke on direct sub-path loads (e.g. `/profile/abc`) and that caused a
  blank/landing page in incognito. Keep them absolute.
- **Backend:** Supabase = Postgres + Auth (email/password + Google OAuth) + Storage + RLS.
  RLS is the security boundary; `security definer` RPCs expose gated data. `is_admin()`
  checks `profiles.role = 'admin'`.
- **Migrations:** `supabase/migrations/0001`–`0022`. The **user runs them manually** in the
  Supabase SQL editor (there's no automated migration step). Latest: 0022 (admin_users +
  title/linkedin). Earlier key ones: 0015 public_code, 0016 portfolio, 0017 education+certs,
  0018–0020 admin analytics, 0021–0022 admin user directory.

## Routing (in index.html)
- `applyRoute(path)`, `showScreen(id)`, `navigate(path)` (= `window.GigCuteNavigate`),
  `PATH_BY_SCREEN` / `SCREEN_BY_PATH`, `gcAwaitAPI()` (resolves `window.GigCuteAPI` robustly).
- Logged-in seekers land on their own profile page `/profile/<code>` (the home).
- Profiles are public (logged-out visitors can view them).
- `/profile/sample` renders a built-in `SAMPLE_PROFILE` through the real profile component.
- Profile codes: 6-char alphanumeric `public_code`; RPCs `public_profile` (by UUID) and
  `public_profile_by_code`. `__shownProfileId` holds the code for share links.

## Key screens / features
- **Profile page** (`showProfilePage(id)`): own vs shared branch. Own renders inside the
  sidebar layout; shared = full page. Toolbar: Copy link, QR code, Print/Save PDF,
  **Interview cheat sheet** (owner only), Log out (owner only).
- **Profile view order** (`renderProfileView`): prompts → Portfolio → Work history →
  Education → Certifications → Skills. "In their own words" panel (`.pv-words`, coral-tinted,
  Fraunces serif italic).
- **Setup flow:** screens `screen-seeker-1` (register: First/Last name, email, password) →
  parsing → `screen-seeker-work` (work history + portfolio + education + certs) →
  `screen-seeker-prompts` → `screen-seeker-preview` → finish.
- **Prompts:** `SEEKER_PROMPT_BANK`. Six early-career prompts are `featured:true` and lead
  the list, each with a "★ Great for new grads & young professionals" badge. The user stars
  up to 3 favorites (shown on the public profile); ALL answered prompts are stored for the
  cheat sheet.
- **Interview cheat sheet:** prompts double as common interview questions. `openCheatSheet()`
  (no args = owner's own answers) / `openSampleCheatSheet()` (homepage sample, `SAMPLE_CHEATSHEET`).
  Renders a white printable doc (`#cheatModal` / `.cheat-doc`), Print uses `body.print-cheat`
  + a print-CSS override so only the sheet prints. Favorites flagged "★ on profile".
- **QR code:** `pvQrBtn` → `#qrModal` full-page with real-world mockups (résumé, two-sided
  horizontal business card, name tag, light closing slide). `gcBuildQrCanvas(url)` uses the
  qrcode lib.
- **Legal:** Terms / Privacy / Cookies / Disclaimer modals (`openLegal(key)`), modeled on
  LinkedIn/Meta, governing law New York (incorporating in NYC), contact gigcutesite@gmail.com.
- **Admin analytics** (`/admin`, `screen-admin`): login-gated (username `admin` → aliases to
  `admin@gigcute.com`). `showAdmin()` → date filter, reset, stat cards (incl. unique visitors,
  signups), activity chart, top referrers/screens, searchable Users directory (email, role,
  title, contact). Secured at the DB level (RPCs return null for non-admins).

## Data model touchpoints (seeker)
- `seeker_profiles` (headline, photo_url, linkedin_url, resume_url, public_code, portfolio[],
  certifications[], is_visible), `work_history`, `education`, `seeker_prompt_answers`
  (prompt_label, answer, is_favorite, sort_order).
- `saveFull(payload)` writes everything; it strips `resume_url/portfolio/certifications` on
  schema-cache errors as a resilience fallback.
- `promptAnswers` now saves **all** answered prompts with `isFavorite` flags (was favorites-only).
  `gcLoadSeekerProfile` loads `seekerProfile.favoritePrompts` (is_favorite) AND
  `seekerProfile.allPrompts` (all). `openProfileEdit` re-seeds all answers, stars favorites.

## Conventions / gotchas
- **Validate before committing:** extract inline `<script>` and run `node --check`; check
  `<div>` vs `</div>` balance (should be 0).
- **Preview MCP:** the proxy 404s on direct sub-paths — load `/` then use `GigCuteNavigate`.
  Always `location.reload()` after edits (an eval right after reload may throw "target
  navigated" — just retry). The screenshot tool times out often; verify via DOM `eval` instead.
- **Security stance the user holds:** don't hardcode passwords (visible in source, and they
  don't unlock server-gated data). The assistant won't enter passwords to authenticate.
- **Memory:** the assistant keeps notes in
  `C:\Users\edios\.claude\projects\C--Users-edios\memory\` (GigCute facts already saved).

## Recent work (this session)
1. Strengthened the homepage value prop (For-job-seekers heading "Showcase more of who you
   are with a GigCute Profile." + new copy about standing out from the crowd / AI sameness).
2. Added a homepage **"How it works"** section (Build → Get link & QR → Share everywhere)
   with Create / Sample CTAs.
3. Built the **interview cheat sheet** feature (homepage teaser + sample, profile button
   replacing "Tips", printable modal, and storing all answered prompts).

Latest commit on `main`: `b8966e6` (interview cheat sheet).

## Likely next steps / open ideas
- Per-profile social share cards / SSR / OG images.
- EU cookie-consent banner; Vercel Web Analytics.
- Optional: corner QR on the printed profile header.
- Existing users only get the FULL cheat sheet after their next profile save (older rows
  stored favorites only).
