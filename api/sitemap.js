// Dynamic sitemaps for the SEO hub pages.
//
//   /sitemap.xml               index -> the children below
//   /sitemap-hubs.xml          role, role x state, remote x role, state hubs
//   /sitemap-companies-N.xml   company hubs, 5k URLs per chunk
//
// Only URLs that clear the depth bar are listed: the RPCs apply a minimum live
// job count, so we never invite Google to crawl a page we would then noindex.
// The protocol caps a sitemap at 50k URLs / 50MB; 5k chunks stay well inside.

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://ztvirfxxyvvcrxcjstzi.supabase.co';
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || 'sb_publishable_G-5zb-7ncuxeOs_jMrjOOw_RDwQsHnc';
const SITE = 'https://www.gigcute.com';
const CHUNK = 5000;
const MIN_COMPANY_JOBS = 5;
const MIN_HUB_JOBS = 25;

const xmlEsc = (s) => String(s == null ? '' : s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;').replace(/'/g, '&apos;');

async function rpc(fn, args) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: 'Bearer ' + SUPABASE_ANON_KEY,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(args),
  });
  if (!r.ok) return null;
  return await r.json();
}

const urlset = (urls) =>
  `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n`
  + urls.map((u) => `<url><loc>${xmlEsc(SITE + u.path)}</loc>`
      + (u.lastmod ? `<lastmod>${xmlEsc(String(u.lastmod).slice(0, 10))}</lastmod>` : '')
      + `<changefreq>daily</changefreq>`
      + (u.priority ? `<priority>${u.priority}</priority>` : '')
      + `</url>`).join('\n')
  + `\n</urlset>`;

export default async function handler(req, res) {
  // Non-production hosts (staging/preview) serve the same code; never let them
  // hand a crawler a sitemap that would compete with production.
  const h = String((req.headers && (req.headers['x-forwarded-host'] || req.headers.host)) || '').toLowerCase();
  if (h && h !== 'www.gigcute.com' && h !== 'gigcute.com') {
    res.setHeader('X-Robots-Tag', 'noindex, nofollow');
    res.setHeader('Content-Type', 'application/xml; charset=utf-8');
    return res.status(404).send('<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"/>');
  }
  const kind = String((req.query && req.query.kind) || 'index').trim();
  const n = Math.max(0, parseInt(String((req.query && req.query.n) || '0'), 10) || 0);

  res.setHeader('Content-Type', 'application/xml; charset=utf-8');
  res.setHeader('Cache-Control', 'public, max-age=0, s-maxage=21600, stale-while-revalidate=86400');

  try {
    if (kind === 'hubs') {
      const hubs = (await rpc('seo_sitemap_hubs', { p_min: MIN_HUB_JOBS })) || [];
      const urls = [
        { path: '/', priority: '1.0' },
        { path: '/jobs', priority: '0.9' },
        ...hubs.map((h) => ({ path: h.path, priority: '0.7' })),
      ];
      return res.status(200).send(urlset(urls));
    }

    if (kind === 'companies') {
      const rows = (await rpc('seo_sitemap_companies', {
        p_min: MIN_COMPANY_JOBS, p_limit: CHUNK, p_offset: n * CHUNK })) || [];
      if (!rows.length) return res.status(404).send('<?xml version="1.0"?><urlset/>');
      return res.status(200).send(urlset(rows.map((r) => ({
        path: `/companies/${r.slug}`, lastmod: r.updated, priority: '0.6' }))));
    }

    // index: how many company chunks do we need?
    const all = (await rpc('seo_sitemap_companies', {
      p_min: MIN_COMPANY_JOBS, p_limit: 50000, p_offset: 0 })) || [];
    const chunks = Math.max(1, Math.ceil(all.length / CHUNK));
    const children = ['/sitemap-hubs.xml']
      .concat(Array.from({ length: chunks }, (_, i) => `/sitemap-companies-${i}.xml`));
    const today = new Date().toISOString().slice(0, 10);
    return res.status(200).send(
      `<?xml version="1.0" encoding="UTF-8"?>\n<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n`
      + children.map((c) => `<sitemap><loc>${xmlEsc(SITE + c)}</loc><lastmod>${today}</lastmod></sitemap>`).join('\n')
      + `\n</sitemapindex>`);
  } catch (e) {
    return res.status(500).send('<?xml version="1.0"?><urlset/>');
  }
}
