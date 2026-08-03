// ============================================================================
// GigCute — calendly-webhook (NOT DEPLOYED YET — pairs with calendly-oauth)
//
// When a candidate books (or cancels) a slot on a recruiter's Calendly, the
// interview appears on the ATS pipeline automatically — no re-typing.
//
// Deploy:
//   supabase functions deploy calendly-webhook --project-ref ztvirfxxyvvcrxcjstzi --no-verify-jwt
// Calendly calls this unauthenticated; the HMAC signature IS the auth, exactly
// like the Stripe webhook. Requires CALENDLY_WEBHOOK_SIGNING_KEY — the same
// value passed to webhook_subscriptions by calendly-oauth.
//
// Mapping a booking to a candidate:
//   1. tracking.utm_content — the application id we embed in the booking link
//      (see atsCalendlyLink in the app). Authoritative.
//   2. fallback: the invitee's email matched to a GigCute candidate who has an
//      application in that recruiter's company.
// Bookings we cannot map are acknowledged and ignored (200) so Calendly does
// not retry forever.
// ============================================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const SIGNING_KEY = Deno.env.get('CALENDLY_WEBHOOK_SIGNING_KEY') ?? '';
const TOLERANCE_SEC = 300;   // reject stale/replayed deliveries

const hex = (buf: ArrayBuffer) =>
  Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('');

// Constant-time compare so we don't leak the signature byte-by-byte.
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function verify(raw: string, header: string | null): Promise<boolean> {
  if (!SIGNING_KEY || !header) return false;
  const parts = Object.fromEntries(header.split(',').map((p) => p.trim().split('=')) as [string, string][]);
  const t = parts['t'], v1 = parts['v1'];
  if (!t || !v1) return false;
  if (Math.abs(Date.now() / 1000 - Number(t)) > TOLERANCE_SEC) return false;

  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(SIGNING_KEY),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${t}.${raw}`));
  return safeEqual(hex(mac), v1);
}

Deno.serve(async (req) => {
  const raw = await req.text();
  if (!(await verify(raw, req.headers.get('Calendly-Webhook-Signature')))) {
    return new Response('Bad signature', { status: 400 });
  }

  let evt: any;
  try { evt = JSON.parse(raw); } catch { return new Response('Bad JSON', { status: 400 }); }
  const kind = evt?.event;
  const p = evt?.payload ?? {};
  // v2 nests the event; older payloads used a bare `event` URI.
  const sched = p.scheduled_event ?? p.event ?? {};
  const eventUri: string | null = (typeof sched === 'string' ? sched : sched?.uri) ?? null;

  if (kind === 'invitee.canceled') {
    if (eventUri) {
      const { data: iv } = await admin.from('interviews')
        .select('id, company_id, application_id').eq('external_event_uri', eventUri).maybeSingle();
      if (iv) {
        await admin.from('interviews').update({ status: 'canceled' }).eq('id', iv.id);
        await admin.from('application_activities').insert({
          company_id: iv.company_id, application_id: iv.application_id,
          type: 'note', body: 'Interview canceled by the candidate in Calendly.',
        });
      }
    }
    return new Response('ok');
  }

  if (kind !== 'invitee.created') return new Response('ignored');

  // Which recruiter's Calendly produced this?
  const ownerUri: string | null = sched?.event_memberships?.[0]?.user ?? null;
  const { data: integ } = await admin.from('integrations')
    .select('profile_id, company_id').eq('provider', 'calendly')
    .eq('external_user_uri', ownerUri ?? '__none__').maybeSingle();
  if (!integ) return new Response('unmapped owner');

  // Which application?
  let appId: string | null = null;
  const tracked = p?.tracking?.utm_content ?? null;
  if (tracked && /^[0-9a-f-]{36}$/i.test(tracked)) {
    const { data: a } = await admin.from('applications')
      .select('id').eq('id', tracked).eq('company_id', integ.company_id).maybeSingle();
    if (a) appId = a.id;
  }
  if (!appId && p?.email) {
    const { data: prof } = await admin.from('profiles')
      .select('id').ilike('email', p.email).maybeSingle();
    if (prof) {
      const { data: a } = await admin.from('applications')
        .select('id').eq('candidate_id', prof.id).eq('company_id', integ.company_id)
        .order('applied_at', { ascending: false }).limit(1).maybeSingle();
      if (a) appId = a.id;
    }
  }
  if (!appId) return new Response('unmapped invitee');

  const start = sched?.start_time ?? null;
  const end = sched?.end_time ?? null;
  const duration = start && end
    ? Math.max(1, Math.round((new Date(end).getTime() - new Date(start).getTime()) / 60000))
    : 30;
  const joinUrl = sched?.location?.join_url ?? sched?.location?.location ?? null;

  // external_event_uri is uniquely indexed, so a redelivered webhook is a no-op.
  const { error: ierr } = await admin.from('interviews').insert({
    company_id: integ.company_id,
    application_id: appId,
    scheduled_at: start,
    duration_min: duration,
    interviewer_id: integ.profile_id,
    location: sched?.location?.type ? `Calendly · ${sched.location.type}` : 'Calendly',
    provider: 'calendly',
    join_url: typeof joinUrl === 'string' && /^https:\/\//i.test(joinUrl) ? joinUrl : null,
    external_event_uri: eventUri,
    created_by: integ.profile_id,
    notes: p?.name ? `Booked by ${p.name}` : null,
  });
  if (ierr && !String(ierr.message || '').includes('duplicate')) {
    return new Response('insert failed', { status: 500 });
  }

  await admin.from('application_activities').insert({
    company_id: integ.company_id, application_id: appId, actor_id: integ.profile_id,
    type: 'note',
    body: `Candidate booked a Calendly slot${start ? ' for ' + new Date(start).toISOString().replace('T', ' ').slice(0, 16) + ' UTC' : ''}.`,
  });

  return new Response('ok');
});
