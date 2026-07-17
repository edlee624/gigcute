// Per-profile social preview cards for /profile/:code.
//
// The site is a client-rendered SPA, so its Open Graph tags only exist after JS
// runs. Social crawlers (LinkedIn, Slack, iMessage, Facebook, X, …) don't run JS,
// so a shared profile link unfurled to the generic site card instead of the
// person's name + headline. vercel.json rewrites ONLY crawler user-agents to this
// function; humans still get the SPA at /index.html untouched.
//
// Public data only: reads the same public_profile_by_code RPC the profile page
// uses (SECURITY DEFINER, gated on seeker_profiles.is_visible). No secrets — the
// anon publishable key is already shipped in public/config.js.

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://ztvirfxxyvvcrxcjstzi.supabase.co';
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || 'sb_publishable_G-5zb-7ncuxeOs_jMrjOOw_RDwQsHnc';
const SITE = 'https://www.gigcute.com';
const DEFAULT_IMAGE = SITE + '/logo.png';

// HTML-escape for use inside double-quoted attributes and text nodes.
function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

async function fetchProfile(code) {
  const r = await fetch(SUPABASE_URL + '/rest/v1/rpc/public_profile_by_code', {
    method: 'POST',
    headers: {
      'apikey': SUPABASE_ANON_KEY,
      'Authorization': 'Bearer ' + SUPABASE_ANON_KEY,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ p_code: code }),
  });
  if (!r.ok) return null;
  const data = await r.json();      // the RPC returns the profile jsonb, or null
  return data && data.name ? data : null;
}

function page({ title, description, image, url, largeImage, name, headline }) {
  const card = largeImage ? 'summary_large_image' : 'summary';
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
<meta property="og:type" content="profile">
<meta property="og:site_name" content="GigCute">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:url" content="${esc(url)}">
<meta property="og:image" content="${esc(image)}">
<meta name="twitter:card" content="${card}">
<meta name="twitter:title" content="${esc(title)}">
<meta name="twitter:description" content="${esc(description)}">
<meta name="twitter:image" content="${esc(image)}">
<link rel="canonical" href="${esc(url)}">
</head><body>
<main style="font-family:system-ui,sans-serif;max-width:520px;margin:12vh auto;padding:0 24px;text-align:center;">
<h1 style="margin:0 0 6px;">${esc(name)}</h1>
<p style="margin:0 0 20px;color:#555;">${esc(headline)}</p>
<p><a href="${esc(url)}">View this profile on GigCute →</a></p>
</main>
</body></html>`;
}

export default async function handler(req, res) {
  const code = String((req.query && req.query.code) || '').trim();
  let prof = null;
  if (code) { try { prof = await fetchProfile(code); } catch (e) { /* fall through to default */ } }

  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  // Cache at the edge for crawlers; profiles change rarely and this is public.
  res.setHeader('Cache-Control', 'public, max-age=0, s-maxage=3600, stale-while-revalidate=86400');

  if (!prof) {
    // Unknown / hidden profile: hand back the site's default card, not a 404, so
    // an unfurl still shows something coherent.
    res.status(200).send(page({
      title: 'GigCute — more than a resume',
      description: 'Answer prompts that show how you actually think, then share your GigCute profile anywhere.',
      image: DEFAULT_IMAGE, largeImage: false, url: SITE,
      name: 'GigCute', headline: 'More than a resume',
    }));
    return;
  }

  const name = prof.name || 'GigCute member';
  const headline = prof.headline || 'On GigCute';
  const photo = typeof prof.photo_url === 'string' && /^https?:\/\//i.test(prof.photo_url) ? prof.photo_url : '';
  res.status(200).send(page({
    title: headline ? `${name} — ${headline}` : name,
    description: `${headline}. See how ${name} thinks — prompts, work, and more on GigCute.`,
    image: photo || DEFAULT_IMAGE,
    largeImage: !!photo,
    url: `${SITE}/profile/${encodeURIComponent(code)}`,
    name, headline,
  }));
}
