// ============================================================================
// GigCute — calendly-oauth (NOT DEPLOYED YET — needs a Calendly app first)
//
// Connects a recruiter's Calendly account so candidates can self-schedule and
// bookings flow straight into the ATS pipeline.
//
// Setup:
//   1. Create an OAuth app at https://calendly.com/integrations/api_webhooks
//      (Developer portal → My Apps → Create app → Web / OAuth 2.0).
//      Redirect URI must be EXACTLY:
//        https://<project-ref>.supabase.co/functions/v1/calendly-oauth?action=callback
//   2. supabase secrets set CALENDLY_CLIENT_ID=... CALENDLY_CLIENT_SECRET=... \
//        CALENDLY_WEBHOOK_SIGNING_KEY=<any long random string> \
//        APP_URL=https://futurestate.gigcute.com
//   3. supabase functions deploy calendly-oauth --project-ref ztvirfxxyvvcrxcjstzi
//      (JWT verification ON: `start` is called with the user's session token.
//       The `callback` leg is authenticated by the one-time `state` nonce, so
//       deploy with --no-verify-jwt ONLY if you also front it with the nonce —
//       which we do. See NOTE below.)
//
// NOTE: Calendly redirects the BROWSER to ?action=callback with no Authorization
// header, so this function must be deployed with --no-verify-jwt. The callback
// is protected by the single-use, 15-minute `state` nonce written by `start`,
// which is itself only reachable with a valid session token.
//
// Uses the SERVICE ROLE key to write integration_tokens (RLS-unreachable from
// clients). Never expose that key client-side.
// ============================================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const admin = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const CLIENT_ID = Deno.env.get('CALENDLY_CLIENT_ID') ?? '';
const CLIENT_SECRET = Deno.env.get('CALENDLY_CLIENT_SECRET') ?? '';
const SIGNING_KEY = Deno.env.get('CALENDLY_WEBHOOK_SIGNING_KEY') ?? '';
const APP_URL = (Deno.env.get('APP_URL') ?? 'https://futurestate.gigcute.com').replace(/\/$/, '');
const REDIRECT_URI = `${SUPABASE_URL}/functions/v1/calendly-oauth?action=callback`;

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const backToApp = (q: string) => new Response(null, { status: 302, headers: { Location: `${APP_URL}/integrations?${q}` } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (!CLIENT_ID || !CLIENT_SECRET) return json({ error: 'Calendly is not configured on this deployment.' }, 503);

  const url = new URL(req.url);
  const action = url.searchParams.get('action') ?? 'start';

  // ---- 1. start: mint a state nonce and hand back the authorize URL --------
  if (action === 'start') {
    const authz = req.headers.get('Authorization') ?? '';
    const token = authz.replace(/^Bearer\s+/i, '');
    if (!token) return json({ error: 'Sign in first.' }, 401);

    const { data: u, error: uerr } = await admin.auth.getUser(token);
    if (uerr || !u?.user) return json({ error: 'Your session has expired — please log in again.' }, 401);

    const state = crypto.randomUUID() + '.' + crypto.randomUUID();
    const { error: serr } = await admin.from('integration_oauth_states')
      .insert({ state, profile_id: u.user.id, provider: 'calendly', redirect_to: `${APP_URL}/integrations` });
    if (serr) return json({ error: 'Could not start the connection.' }, 500);

    const authorize = new URL('https://auth.calendly.com/oauth/authorize');
    authorize.searchParams.set('client_id', CLIENT_ID);
    authorize.searchParams.set('response_type', 'code');
    authorize.searchParams.set('redirect_uri', REDIRECT_URI);
    authorize.searchParams.set('state', state);
    return json({ authorize_url: authorize.toString() });
  }

  // ---- 2. callback: exchange the code, store tokens, register the webhook --
  if (action === 'callback') {
    const code = url.searchParams.get('code');
    const state = url.searchParams.get('state');
    if (!code || !state) return backToApp('calendly=error&reason=missing_code');

    // Single-use nonce: consume it immediately so a replayed callback fails.
    const { data: st } = await admin.from('integration_oauth_states')
      .select('state, profile_id, expires_at').eq('state', state).maybeSingle();
    if (!st) return backToApp('calendly=error&reason=bad_state');
    await admin.from('integration_oauth_states').delete().eq('state', state);
    if (new Date(st.expires_at).getTime() < Date.now()) return backToApp('calendly=error&reason=expired');

    // Exchange the authorization code for tokens.
    const tokRes = await fetch('https://auth.calendly.com/oauth/token', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Authorization: 'Basic ' + btoa(`${CLIENT_ID}:${CLIENT_SECRET}`),
      },
      body: new URLSearchParams({ grant_type: 'authorization_code', code, redirect_uri: REDIRECT_URI }),
    });
    if (!tokRes.ok) return backToApp('calendly=error&reason=token_exchange');
    const tok = await tokRes.json();

    // Who did we just connect?
    const meRes = await fetch('https://api.calendly.com/users/me', {
      headers: { Authorization: `Bearer ${tok.access_token}` },
    });
    if (!meRes.ok) return backToApp('calendly=error&reason=profile');
    const me = (await meRes.json()).resource;

    const { data: integ, error: ierr } = await admin.from('integrations').upsert({
      profile_id: st.profile_id,
      provider: 'calendly',
      mode: 'oauth',
      status: 'active',
      display_name: me?.name ?? null,
      link: me?.scheduling_url ?? null,
      external_user_uri: me?.uri ?? null,
      external_org_uri: me?.current_organization ?? null,
      meta: { timezone: me?.timezone ?? null, email: me?.email ?? null },
      connected_at: new Date().toISOString(),
    }, { onConflict: 'profile_id,provider' }).select('id').single();
    if (ierr || !integ) return backToApp('calendly=error&reason=save');

    await admin.from('integration_tokens').upsert({
      integration_id: integ.id,
      access_token: tok.access_token,
      refresh_token: tok.refresh_token ?? null,
      expires_at: tok.expires_in ? new Date(Date.now() + tok.expires_in * 1000).toISOString() : null,
      updated_at: new Date().toISOString(),
    });

    // Subscribe to bookings so they land in the pipeline automatically.
    if (SIGNING_KEY && me?.uri && me?.current_organization) {
      await fetch('https://api.calendly.com/webhook_subscriptions', {
        method: 'POST',
        headers: { Authorization: `Bearer ${tok.access_token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          url: `${SUPABASE_URL}/functions/v1/calendly-webhook`,
          events: ['invitee.created', 'invitee.canceled'],
          organization: me.current_organization,
          user: me.uri,
          scope: 'user',
          signing_key: SIGNING_KEY,
        }),
      }).catch(() => {});   // a duplicate subscription is fine — connection still succeeded
    }

    return backToApp('calendly=connected');
  }

  return json({ error: 'Unknown action.' }, 400);
});
