// ============================================================================
// GigCute — delete-account Edge Function
// Lets a signed-in user permanently delete their OWN account. The client calls
// this with its user session; we identify the caller from their JWT and delete
// that auth user with the service role. auth.users deletion cascades to
// public.profiles (FK on delete cascade) and from there to seeker_profiles,
// work_history, prompt answers, tracked_jobs, interest, etc.
//
// Deploy with JWT verification ON (only authenticated callers reach it):
//   supabase functions deploy delete-account --project-ref ztvirfxxyvvcrxcjstzi
//
// Env: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY are injected
// automatically by the platform — no manual secrets needed.
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const authHeader = req.headers.get("Authorization") || "";
  if (!authHeader) return json({ error: "not authenticated" }, 401);

  // Identify the caller from their JWT (never trust an id from the request body).
  const userClient = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
  const { data: { user }, error: uErr } = await userClient.auth.getUser();
  if (uErr || !user) return json({ error: "not authenticated" }, 401);

  // Delete with the service role; profiles + child rows cascade via FKs.
  const admin = createClient(url, service);
  const { error: dErr } = await admin.auth.admin.deleteUser(user.id);
  if (dErr) return json({ error: dErr.message }, 500);

  return json({ ok: true, deleted: user.id });
});
