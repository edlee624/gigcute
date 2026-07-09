// ============================================================================
// GigCute — create-checkout (Build 2, HIDDEN / NOT DEPLOYED YET)
// Creates a Stripe Checkout Session for a plan and returns { url }.
//
// Before deploying:
//   1. Decide pricing; create a Stripe Product + recurring Price per paid plan.
//   2. Set secrets on the project:
//        supabase secrets set STRIPE_SECRET_KEY=sk_live_...
//        supabase secrets set STRIPE_PRICE_STARTER=price_... \
//                             STRIPE_PRICE_PRO=price_... STRIPE_PRICE_GOD=price_...
//        supabase secrets set CHECKOUT_SUCCESS_URL=https://futurestate.gigcute.com/hiring?upgraded=1 \
//                             CHECKOUT_CANCEL_URL=https://futurestate.gigcute.com/hiring
//   3. Deploy: supabase functions deploy create-checkout --project-ref ztvirfxxyvvcrxcjstzi
//   4. In the app set window.GIGCUTE_FUNCTIONS_URL and flip GC_SHOW_UPGRADE = true.
// ============================================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'https://esm.sh/stripe@14?target=deno';

const PRICE_BY_PLAN: Record<string, string | undefined> = {
  starter: Deno.env.get('STRIPE_PRICE_STARTER'),
  pro:     Deno.env.get('STRIPE_PRICE_PRO'),
  god:     Deno.env.get('STRIPE_PRICE_GOD'),
};

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY')!, { apiVersion: '2024-06-20' });
    const { plan } = await req.json();
    const price = PRICE_BY_PLAN[plan];
    if (!price) return json({ error: 'Unknown or unpriced plan.' }, 400);

    // Identify the caller and the company they own.
    const supa = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: req.headers.get('Authorization') || '' } },
    });
    const { data: u } = await supa.auth.getUser();
    if (!u?.user) return json({ error: 'Not signed in.' }, 401);
    const { data: co } = await supa.from('companies').select('id').eq('owner_id', u.user.id).limit(1).maybeSingle();
    if (!co) return json({ error: 'No company found.' }, 400);

    const session = await stripe.checkout.sessions.create({
      mode: 'subscription',
      line_items: [{ price, quantity: 1 }],
      success_url: Deno.env.get('CHECKOUT_SUCCESS_URL') || 'https://futurestate.gigcute.com/hiring',
      cancel_url:  Deno.env.get('CHECKOUT_CANCEL_URL')  || 'https://futurestate.gigcute.com/hiring',
      client_reference_id: co.id,          // company_id, echoed back by the webhook
      metadata: { company_id: co.id, plan },
      subscription_data: { metadata: { company_id: co.id, plan } },
    });
    return json({ url: session.url });
  } catch (e) {
    return json({ error: String(e?.message || e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
}
