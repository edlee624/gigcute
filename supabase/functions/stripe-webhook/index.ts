// ============================================================================
// GigCute — stripe-webhook (Build 2, HIDDEN / NOT DEPLOYED YET)
// Verifies Stripe events and upserts public.subscriptions; the sync_company_plan
// trigger (migration 0062) then updates companies.plan, which drives all limits.
//
// Before deploying:
//   1. supabase secrets set STRIPE_SECRET_KEY=sk_live_... STRIPE_WEBHOOK_SECRET=whsec_...
//   2. Deploy WITHOUT jwt (Stripe calls it unauthenticated; the signature is the auth):
//        supabase functions deploy stripe-webhook --project-ref ztvirfxxyvvcrxcjstzi --no-verify-jwt
//   3. In the Stripe dashboard add the endpoint URL and subscribe to:
//        checkout.session.completed, customer.subscription.updated,
//        customer.subscription.deleted
// Uses the SERVICE ROLE key to write subscriptions (bypasses RLS). Never expose it client-side.
// ============================================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'https://esm.sh/stripe@14?target=deno';

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY')!, { apiVersion: '2024-06-20' });
const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

Deno.serve(async (req) => {
  const sig = req.headers.get('stripe-signature');
  const raw = await req.text();
  let evt: Stripe.Event;
  try {
    evt = await stripe.webhooks.constructEventAsync(raw, sig!, Deno.env.get('STRIPE_WEBHOOK_SECRET')!);
  } catch (e) {
    return new Response(`Bad signature: ${e?.message}`, { status: 400 });
  }

  try {
    if (evt.type === 'checkout.session.completed') {
      const s = evt.data.object as Stripe.Checkout.Session;
      const companyId = (s.metadata?.company_id) || (s.client_reference_id ?? undefined);
      const plan = s.metadata?.plan || 'starter';
      if (companyId) {
        await admin.from('subscriptions').upsert({
          company_id: companyId, plan,
          stripe_customer_id: String(s.customer ?? ''),
          stripe_subscription_id: String(s.subscription ?? ''),
          status: 'active', updated_at: new Date().toISOString(),
        }, { onConflict: 'company_id' });
      }
    } else if (evt.type === 'customer.subscription.updated' || evt.type === 'customer.subscription.deleted') {
      const sub = evt.data.object as Stripe.Subscription;
      const companyId = sub.metadata?.company_id;
      const plan = sub.metadata?.plan || 'starter';
      if (companyId) {
        await admin.from('subscriptions').upsert({
          company_id: companyId, plan,
          stripe_customer_id: String(sub.customer ?? ''),
          stripe_subscription_id: sub.id,
          status: sub.status,   // active / past_due / canceled → trigger maps non-active to free
          current_period_end: new Date(sub.current_period_end * 1000).toISOString(),
          updated_at: new Date().toISOString(),
        }, { onConflict: 'company_id' });
      }
    }
    return new Response('ok', { status: 200 });
  } catch (e) {
    return new Response(`handler error: ${e?.message}`, { status: 500 });
  }
});
