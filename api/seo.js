// Server-rendered SEO hub pages.
//
// The site is a client-rendered SPA, so every URL returns the same empty shell —
// nothing for a crawler to index. This function renders real HTML for the hub
// pages that carry long-tail search demand:
//
//   /companies/:slug        Jobs at <Company>
//   /jobs/:role             <Role> jobs
//   /jobs/:role/:state      <Role> jobs in <State>
//   /jobs/remote/:role      Remote <Role> jobs
//   /jobs/in/:state         Jobs in <State>
//
// Served to EVERYONE, not just crawlers. Serving crawler-only HTML is cloaking;
// the same URL must give humans and Googlebot the same content. The page is a
// real, useful listing that then links into the SPA.
//
// NOTE ON STRUCTURED DATA: these jobs are ingested from employers' own ATS
// boards, so they are NOT marked up as JobPosting — that would duplicate the
// employer's canonical listing. Hubs use ItemList + BreadcrumbList, which
// describe *this collection*, and every job links out to the employer's URL.
// Only jobs posted natively on GigCute may ever carry JobPosting markup.

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://ztvirfxxyvvcrxcjstzi.supabase.co';
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || 'sb_publishable_G-5zb-7ncuxeOs_jMrjOOw_RDwQsHnc';
const SITE = 'https://www.gigcute.com';

// A hub thinner than this is noindex,follow — it still passes link equity, but
// we never ask Google to index a page with nothing on it. Thin programmatic
// pages are the single most common way this kind of engine gets penalised.
const MIN_INDEXABLE = 5;

const STATES = {
  al:'Alabama',ak:'Alaska',az:'Arizona',ar:'Arkansas',ca:'California',co:'Colorado',ct:'Connecticut',
  de:'Delaware',fl:'Florida',ga:'Georgia',hi:'Hawaii',id:'Idaho',il:'Illinois',in:'Indiana',ia:'Iowa',
  ks:'Kansas',ky:'Kentucky',la:'Louisiana',me:'Maine',md:'Maryland',ma:'Massachusetts',mi:'Michigan',
  mn:'Minnesota',ms:'Mississippi',mo:'Missouri',mt:'Montana',ne:'Nebraska',nv:'Nevada',nh:'New Hampshire',
  nj:'New Jersey',nm:'New Mexico',ny:'New York',nc:'North Carolina',nd:'North Dakota',oh:'Ohio',
  ok:'Oklahoma',or:'Oregon',pa:'Pennsylvania',ri:'Rhode Island',sc:'South Carolina',sd:'South Dakota',
  tn:'Tennessee',tx:'Texas',ut:'Utah',vt:'Vermont',va:'Virginia',wa:'Washington',wv:'West Virginia',
  wi:'Wisconsin',wy:'Wyoming',dc:'District of Columbia',pr:'Puerto Rico',
};

function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
const money = (n) => (n == null ? null : '$' + Math.round(Number(n) / 1000) + 'k');

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

function jobRow(j, showCompany) {
  const loc = j.remote ? 'Remote' : (j.location || '');
  const pay = (j.salary_min && j.salary_max) ? ` · ${money(j.salary_min)}–${money(j.salary_max)}` : '';
  const sub = [showCompany ? j.company : null, loc].filter(Boolean).join(' · ');
  // rel=nofollow: these point at employers' boards, not endorsements, and it
  // keeps crawl budget on our own hub mesh.
  return `<li class="j">
    <a class="t" href="${esc(j.url || '#')}" target="_blank" rel="nofollow noopener">${esc(j.title || 'Role')}</a>
    <span class="m">${esc(sub)}${pay}</span>
  </li>`;
}

function shell({ title, description, path, h1, intro, body, links, jsonld, indexable }) {
  const url = SITE + path;
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
<link rel="canonical" href="${esc(url)}">
${indexable ? '' : '<meta name="robots" content="noindex,follow">\n'}<meta property="og:type" content="website">
<meta property="og:site_name" content="GigCute">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:url" content="${esc(url)}">
<meta property="og:image" content="${SITE}/logo.png">
<meta name="twitter:card" content="summary">
<script type="application/ld+json">${JSON.stringify(jsonld)}</script>
<style>
:root{--bg:#12141a;--fg:#f2f0ea;--mut:#9aa0ab;--line:#252932;--sage:#8fae86}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.55 Inter,system-ui,sans-serif}
a{color:inherit}
.wrap{max-width:860px;margin:0 auto;padding:28px 22px 64px}
header{display:flex;justify-content:space-between;align-items:center;margin-bottom:28px}
.brand{font-weight:700;letter-spacing:-.02em;text-decoration:none}
.cta{border:1px solid var(--sage);color:var(--sage);border-radius:9px;padding:7px 14px;text-decoration:none;font-size:13px}
h1{font-size:28px;line-height:1.2;margin:0 0 8px;letter-spacing:-.02em}
.intro{color:var(--mut);margin:0 0 22px}
.stats{display:flex;gap:10px;flex-wrap:wrap;margin:0 0 24px;padding:0;list-style:none}
.stats li{border:1px solid var(--line);border-radius:11px;padding:10px 14px;min-width:120px}
.stats b{display:block;font-size:19px}
.stats span{color:var(--mut);font-size:12px}
ul.jobs{list-style:none;padding:0;margin:0 0 26px;border-top:1px solid var(--line)}
li.j{padding:12px 2px;border-bottom:1px solid var(--line)}
li.j .t{font-weight:600;text-decoration:none}
li.j .t:hover{color:var(--sage)}
li.j .m{display:block;color:var(--mut);font-size:13px;margin-top:2px}
nav.rel{border-top:1px solid var(--line);padding-top:18px}
nav.rel h2{font-size:14px;color:var(--mut);font-weight:600;margin:0 0 10px}
nav.rel a{display:inline-block;border:1px solid var(--line);border-radius:8px;padding:6px 11px;margin:0 6px 8px 0;font-size:13px;text-decoration:none}
nav.rel a:hover{border-color:var(--sage);color:var(--sage)}
footer{margin-top:34px;color:var(--mut);font-size:12.5px}
</style>
</head><body>
<div class="wrap">
<header>
  <a class="brand" href="${SITE}/">GigCute</a>
  <a class="cta" href="${SITE}/jobs">Search all jobs →</a>
</header>
<main>
<h1>${esc(h1)}</h1>
<p class="intro">${esc(intro)}</p>
${body}
</main>
${links}
<footer>Listings are aggregated from employers' own career sites and application pages. Applying takes you to the employer.</footer>
</div>
</body></html>`;
}

function statsList(items) {
  const li = items.filter(Boolean).map(i => `<li><b>${esc(i.v)}</b><span>${esc(i.k)}</span></li>`).join('');
  return li ? `<ul class="stats">${li}</ul>` : '';
}
function linkBlock(title, items) {
  if (!items || !items.length) return '';
  return `<nav class="rel"><h2>${esc(title)}</h2>${items.map(i =>
    `<a href="${esc(i.href)}">${esc(i.label)}</a>`).join('')}</nav>`;
}
function breadcrumbs(trail) {
  return {
    '@context': 'https://schema.org', '@type': 'BreadcrumbList',
    itemListElement: trail.map((t, i) => ({
      '@type': 'ListItem', position: i + 1, name: t.name, item: SITE + t.path })),
  };
}
function itemList(jobs, name) {
  return {
    '@context': 'https://schema.org', '@type': 'ItemList', name,
    numberOfItems: jobs.length,
    itemListElement: jobs.slice(0, 25).map((j, i) => ({
      '@type': 'ListItem', position: i + 1,
      name: [j.title, j.company].filter(Boolean).join(' — '), url: j.url })),
  };
}

function notFound(res) {
  res.status(404).setHeader('Content-Type', 'text/html; charset=utf-8');
  res.send(shell({
    title: 'Not found — GigCute', description: 'This page does not exist.',
    path: '/', h1: 'Nothing here', intro: 'That page has no live jobs right now.',
    body: '', links: linkBlock('Try these', [{ href: SITE + '/jobs', label: 'Search all jobs' }]),
    jsonld: breadcrumbs([{ name: 'GigCute', path: '/' }]), indexable: false,
  }));
}

// Only the canonical production host may be indexed. staging/futurestate and
// Vercel preview URLs serve the same pages, and letting them into the index
// would compete with production as duplicate content.
function isCanonicalHost(req) {
  const h = String((req.headers && (req.headers['x-forwarded-host'] || req.headers.host)) || '').toLowerCase();
  return h === 'www.gigcute.com' || h === 'gigcute.com';
}

export default async function handler(req, res) {
  const canonicalHost = isCanonicalHost(req);
  if (!canonicalHost) res.setHeader('X-Robots-Tag', 'noindex, nofollow');
  const kind = String((req.query && req.query.kind) || '').trim();
  const a = String((req.query && req.query.a) || '').trim().toLowerCase();
  const b = String((req.query && req.query.b) || '').trim().toLowerCase();

  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  // Jobs churn daily, not hourly. Cache hard at the edge, revalidate in the
  // background so a crawler never waits on a cold render.
  res.setHeader('Cache-Control', 'public, max-age=0, s-maxage=21600, stale-while-revalidate=86400');

  try {
    if (kind === 'company') {
      const d = await rpc('seo_company', { p_slug: a, p_limit: 50 });
      if (!d || !d.name) return notFound(res);
      const s = d.salary || {};
      const path = `/companies/${a}`;
      const title = `Jobs at ${d.name} — ${d.total} open role${d.total === 1 ? '' : 's'} | GigCute`;
      const desc = `${d.total} open role${d.total === 1 ? '' : 's'} at ${d.name}`
        + (s.median ? `, median pay around ${money(s.median)}` : '') + '. Updated daily on GigCute.';
      return res.status(200).send(shell({
        title, description: desc, path,
        h1: `Jobs at ${d.name}`,
        intro: `${d.total} open role${d.total === 1 ? '' : 's'} right now`
          + (s.median ? `, typically ${money(s.min)}–${money(s.max)}.` : '.'),
        body: statsList([
          { k: 'Open roles', v: d.total },
          s.median ? { k: 'Median pay', v: money(s.median) } : null,
          (d.locations && d.locations[0]) ? { k: 'Top location', v: d.locations[0].state } : null,
        ]) + `<ul class="jobs">${(d.jobs || []).map(j => jobRow(j, false)).join('')}</ul>`,
        links: linkBlock('Roles at this company', (d.roles || []).map(r => ({
            href: `${SITE}/jobs/${r.slug}`, label: `${r.slug.replace(/-/g, ' ')} (${r.n})` })))
          + linkBlock('Where they hire', (d.locations || []).map(l => ({
            href: `${SITE}/jobs/in/${String(l.state).toLowerCase()}`,
            label: `${STATES[String(l.state).toLowerCase()] || l.state} (${l.n})` }))),
        jsonld: [
          breadcrumbs([{ name: 'GigCute', path: '/' }, { name: 'Companies', path: '/companies' }, { name: d.name, path }]),
          itemList(d.jobs || [], `Open roles at ${d.name}`),
        ],
        // `named` is false when the ingested company value is an ATS board
        // handle rather than a display name — a poor page we still serve but
        // never ask Google to index.
        indexable: canonicalHost && d.total >= MIN_INDEXABLE && d.named !== false,
      }));
    }

    if (kind === 'role' || kind === 'remote' || kind === 'state') {
      const isState = kind === 'state';
      const role = isState ? null : a;
      const st = kind === 'role' ? b : (isState ? a : null);
      if (st && !STATES[st]) return notFound(res);

      let d;
      if (isState) {
        d = await rpc('seo_state', { p_state: a, p_limit: 50 });
        if (!d || !d.total) return notFound(res);
        d.label = 'Jobs';           // role-agnostic hub
      } else {
        d = await rpc('seo_role', { p_role: role, p_state: st || null, p_remote: kind === 'remote', p_limit: 50 });
        if (!d || !d.label) return notFound(res);
      }

      const stName = st ? STATES[st] : null;
      const s = d.salary || {};
      const path = isState ? `/jobs/in/${st}`
        : kind === 'remote' ? `/jobs/remote/${role}`
        : st ? `/jobs/${role}/${st}` : `/jobs/${role}`;
      const what = isState ? 'Jobs' : `${d.label} jobs`;
      const where = kind === 'remote' ? 'Remote' : (stName ? `in ${stName}` : '');
      const h1 = kind === 'remote' ? `Remote ${d.label.toLowerCase()} jobs`
        : `${what}${where ? ' ' + where : ''}`;
      const title = `${h1} — ${d.total} open | GigCute`;
      const desc = `${d.total} ${where ? where.toLowerCase() + ' ' : ''}${d.label.toLowerCase()} role${d.total === 1 ? '' : 's'}`
        + (s.median ? `, median around ${money(s.median)}` : '') + '. Fresh listings from employers, updated daily.';

      const siblings = [];
      if (!isState && !st && kind !== 'remote') siblings.push({ href: `${SITE}/jobs/remote/${role}`, label: `Remote ${d.label.toLowerCase()}` });
      if (!isState && st) siblings.push({ href: `${SITE}/jobs/${role}`, label: `All ${d.label.toLowerCase()} jobs` });

      return res.status(200).send(shell({
        title, description: desc, path, h1,
        intro: `${d.total} open role${d.total === 1 ? '' : 's'}`
          + (s.median ? `, typically ${money(s.min)}–${money(s.max)}.` : '.'),
        body: statsList([
          { k: 'Open roles', v: d.total },
          s.median ? { k: 'Median pay', v: money(s.median) } : null,
          (d.companies && d.companies[0]) ? { k: 'Top employer', v: d.companies[0].name } : null,
        ]) + `<ul class="jobs">${(d.jobs || []).map(j => jobRow(j, true)).join('')}</ul>`,
        links: linkBlock('Top employers hiring', (d.companies || []).map(c => ({
            href: `${SITE}/companies/${c.slug}`, label: `${c.name} (${c.n})` })))
          // A state hub fans out to roles within that state; a role hub fans out
          // to states. Either way every hub links onward into the mesh.
          + (isState
              ? linkBlock(`Roles in ${stName}`, (d.roles || []).map(r => ({
                  href: `${SITE}/jobs/${r.slug}/${st}`,
                  label: `${r.slug.replace(/-/g, ' ')} (${r.n})` })))
              : linkBlock('By state', (d.states || []).map(x => ({
                  href: `${SITE}/jobs/${role}/${String(x.state).toLowerCase()}`,
                  label: `${STATES[String(x.state).toLowerCase()] || x.state} (${x.n})` }))))
          + linkBlock('Related', siblings),
        jsonld: [
          breadcrumbs([{ name: 'GigCute', path: '/' }, { name: 'Jobs', path: '/jobs' }, { name: h1, path }]),
          itemList(d.jobs || [], h1),
        ],
        indexable: canonicalHost && d.total >= MIN_INDEXABLE,
      }));
    }

    return notFound(res);
  } catch (e) {
    return notFound(res);
  }
}
