# GigCute — Deployment Guide

## Current state
The prototype is a single-page static HTML app. No build step, no dependencies, no server required.

---

## Part 1: Deploy to Vercel (do this now)

### Option A: Drag and drop (fastest, under 2 minutes)
1. Go to [vercel.com](https://vercel.com) and sign in (or create a free account)
2. Click **Add New → Project**
3. Choose **"Deploy from the file system"** or drag the entire `gigcute-deploy` folder onto the dashboard
4. Vercel auto-detects it as a static site
5. Click **Deploy**
6. You'll get a live URL like `gigcute.vercel.app` in about 30 seconds

### Option B: GitHub → Vercel (recommended for ongoing development)
1. Create a GitHub repo: `github.com/new` — name it `gigcute`
2. Push this folder:
   ```bash
   cd gigcute-deploy
   git init
   git add .
   git commit -m "Initial GigCute prototype"
   git remote add origin https://github.com/YOUR_USERNAME/gigcute.git
   git push -u origin main
   ```
3. Go to [vercel.com](https://vercel.com) → **Add New → Project**
4. Import your `gigcute` GitHub repo
5. Vercel reads `vercel.json` automatically — no config needed
6. Click **Deploy**

From this point on, every `git push` to `main` auto-deploys to Vercel.

### Custom domain
1. In your Vercel project, go to **Settings → Domains**
2. Add `gigcute.com` (or whatever you own)
3. Follow the DNS instructions — typically two records at your registrar:
   - `A` record pointing to `76.76.21.21`
   - `CNAME` `www` pointing to `cname.vercel-dns.com`

### Local development
```bash
npm install
npm run dev
# Opens at http://localhost:3000
```

---

## Part 2: Railway backend (when you're ready to go real)

Railway hosts your backend API, database (Postgres), and any services. You'll need this when you:
- Replace the mock data with a real database
- Add real authentication (Clerk/Auth0 or your own)
- Build the matching API, messaging, notifications, etc.

### What lives on Railway
- **Postgres database** — all users, postings, matches, messages
- **Node.js/Express API** (or Next.js API routes) — business logic
- **Redis** — sessions, real-time pubsub for chat

### Setup (when ready)
1. Go to [railway.app](https://railway.app) and sign in with GitHub
2. **New Project → Deploy from GitHub repo**
3. Select your repo (or a separate `gigcute-api` repo)
4. Click **+ Add Plugin → Postgres** — Railway provisions it instantly
5. Your `DATABASE_URL` env var is auto-injected
6. Add a **Redis** plugin the same way for sessions/chat

### Connect Vercel to Railway
In your Vercel project → **Settings → Environment Variables**, add:
```
NEXT_PUBLIC_API_URL=https://gigcute-api.up.railway.app
DATABASE_URL=postgresql://...   (from Railway dashboard)
```

### Recommended stack when going production
| Layer | Technology | Where |
|---|---|---|
| Frontend | Next.js 14 (App Router) | Vercel |
| Auth | Clerk | Vercel + API |
| API | Next.js API Routes or Express | Vercel or Railway |
| Database | Postgres | Railway |
| Sessions | Redis | Railway |
| File storage | Cloudflare R2 | Cloudflare |
| Email | Resend | API calls |
| Search | Algolia or Typesense | Managed |

---

## Migration path from prototype → production

1. **Phase 1 (now):** Deploy static prototype to Vercel → share with investors/users for feedback
2. **Phase 2:** Scaffold a Next.js app, move the HTML/CSS/JS into React components
3. **Phase 3:** Add Clerk auth, connect Postgres on Railway, replace mock data with real API calls
4. **Phase 4:** Add real-time messaging (Socket.io or Supabase Realtime), email notifications (Resend), and search (Algolia)

---

## Estimated costs at launch scale

| Service | Free tier | Paid |
|---|---|---|
| Vercel | 100GB bandwidth/mo | $20/mo (Pro) |
| Railway | $5 credit/mo | ~$10–20/mo (small Postgres + API) |
| Clerk | 10,000 MAU free | $25/mo |
| Resend | 3,000 emails/mo free | $20/mo |
| Algolia | 10,000 records free | $50/mo |

**Total at launch: $0–$25/mo on free tiers**, scaling to ~$100–200/mo with real traffic.
