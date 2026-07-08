// ============================================================================
// GigCute — notify-invite Edge Function
// Sends email for invite events, called by a DB trigger on public.invites via
// pg_net (x-notify-secret header). Uses the service role to read the recipient's
// email + posting/company, and Resend to send.
//   invite_created  -> email the candidate  ("<Company> wants to chat")
//   invite_accepted -> email the company owner ("<Candidate> accepted")
//   invite_declined -> email the company owner ("<Candidate> declined")
//
// Deploy with JWT verification OFF (it's protected by NOTIFY_SECRET):
//   supabase functions deploy notify-invite --project-ref ztvirfxxyvvcrxcjstzi --no-verify-jwt
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (auto), RESEND_API_KEY,
//      NOTIFY_SECRET, APP_URL (default https://futurestate.gigcute.com).
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });
const esc = (s: string) => String(s || "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
const APP = Deno.env.get("APP_URL") || "https://futurestate.gigcute.com";
const FROM = "GigCute <noreply@gigcute.com>";

async function sendEmail(to: string | undefined, subject: string, html: string) {
  if (!to) return;
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${Deno.env.get("RESEND_API_KEY")}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to: [to], subject, html }),
  });
  if (!r.ok) console.warn("resend", r.status, await r.text());
}
const shell = (body: string) =>
  `<div style="font-family:Inter,Arial,sans-serif;max-width:520px;margin:0 auto;color:#20242c;">
     <div style="font-family:Georgia,serif;font-size:22px;font-weight:600;color:#ff5a3c;margin-bottom:16px;">GigCute</div>
     ${body}
     <p style="font-size:12px;color:#9aa;margin-top:24px;">You're receiving this because of activity on your GigCute account.</p>
   </div>`;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  if ((req.headers.get("x-notify-secret") || "") !== Deno.env.get("NOTIFY_SECRET")) return json({ error: "unauthorized" }, 401);
  const { invite_id, event } = await req.json().catch(() => ({}));
  if (!invite_id || !event) return json({ error: "bad request" }, 400);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: inv } = await admin.from("invites").select("id, seeker_id, posting_id, note, status").eq("id", invite_id).single();
  if (!inv) return json({ error: "invite not found" }, 404);
  const { data: posting } = await admin.from("postings").select("title, companies(name, owner_id)").eq("id", inv.posting_id).single();
  const role = (posting as any)?.title || "a role";
  const company = (posting as any)?.companies?.name || "A company";

  if (event === "invite_created") {
    const { data: u } = await admin.auth.admin.getUserById(inv.seeker_id);
    const body = `<p style="font-size:15px;line-height:1.5;"><b>${esc(company)}</b> invited you to connect about <b>${esc(role)}</b>.</p>
      ${inv.note ? `<p style="font-size:14px;color:#555;border-left:3px solid #eee;padding-left:12px;">${esc(inv.note)}</p>` : ""}
      <p style="margin-top:20px;"><a href="${APP}/messages" style="background:#ff5a3c;color:#fff;text-decoration:none;padding:11px 20px;border-radius:10px;font-weight:600;">View invitation →</a></p>`;
    await sendEmail(u?.user?.email, `${company} wants to chat — ${role}`, shell(body));
  } else if (event === "invite_accepted" || event === "invite_declined") {
    const ownerId = (posting as any)?.companies?.owner_id;
    if (ownerId) {
      const { data: ou } = await admin.auth.admin.getUserById(ownerId);
      const { data: seeker } = await admin.from("profiles").select("full_name").eq("id", inv.seeker_id).single();
      const who = seeker?.full_name || "A candidate";
      const accepted = event === "invite_accepted";
      const body = `<p style="font-size:15px;line-height:1.5;"><b>${esc(who)}</b> ${accepted ? "accepted" : "declined"} your invite for <b>${esc(role)}</b>.</p>
        ${accepted ? `<p style="margin-top:20px;"><a href="${APP}/messages" style="background:#ff5a3c;color:#fff;text-decoration:none;padding:11px 20px;border-radius:10px;font-weight:600;">Open the conversation →</a></p>` : ""}`;
      await sendEmail(ou?.user?.email, `${who} ${accepted ? "accepted" : "declined"} your invite — ${role}`, shell(body));
    }
  }
  return json({ ok: true });
});
