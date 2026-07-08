// ============================================================================
// GigCute — notify-message Edge Function
// Called by a trigger on public.messages (pg_net, x-notify-secret). Emails the
// OTHER participant when they receive a message — gated by their notification
// pref (email_messages) and debounced to at most one email per conversation per
// 15 minutes so a rapid back-and-forth doesn't spam the inbox.
//
// Deploy JWT-off: supabase functions deploy notify-message --project-ref ztvirfxxyvvcrxcjstzi --no-verify-jwt
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (auto), RESEND_API_KEY,
//      NOTIFY_SECRET, APP_URL (default https://futurestate.gigcute.com).
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });
const esc = (s: string) => String(s || "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
const APP = Deno.env.get("APP_URL") || "https://futurestate.gigcute.com";
const FROM = "GigCute <noreply@gigcute.com>";
const DEBOUNCE_MS = 15 * 60 * 1000;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  if ((req.headers.get("x-notify-secret") || "") !== Deno.env.get("NOTIFY_SECRET")) return json({ error: "unauthorized" }, 401);
  const { message_id } = await req.json().catch(() => ({}));
  if (!message_id) return json({ error: "bad request" }, 400);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: msg } = await admin.from("messages").select("id, conversation_id, sender_id, body").eq("id", message_id).single();
  if (!msg || !msg.sender_id) return json({ ok: true, skipped: "no sender" });

  const { data: conv } = await admin.from("conversations")
    .select("id, seeker_id, postings(title, companies(name, owner_id))").eq("id", msg.conversation_id).single();
  if (!conv) return json({ ok: true, skipped: "no conversation" });

  const seekerId = (conv as any).seeker_id;
  const ownerId = (conv as any).postings?.companies?.owner_id;
  const company = (conv as any).postings?.companies?.name || "the hiring team";
  const role = (conv as any).postings?.title || "a role";
  const senderIsSeeker = msg.sender_id === seekerId;
  const recipientId = senderIsSeeker ? ownerId : seekerId;
  if (!recipientId || recipientId === msg.sender_id) return json({ ok: true, skipped: "no recipient" });

  // Recipient opted out?
  const { data: pref } = await admin.from("notification_prefs").select("email_messages").eq("user_id", recipientId).maybeSingle();
  if (pref && pref.email_messages === false) return json({ ok: true, skipped: "opted out" });

  // Debounce per conversation+recipient.
  const { data: st } = await admin.from("message_notify_state").select("last_email_at")
    .eq("conversation_id", msg.conversation_id).eq("recipient_id", recipientId).maybeSingle();
  if (st && (Date.now() - new Date(st.last_email_at).getTime()) < DEBOUNCE_MS) return json({ ok: true, skipped: "debounced" });

  // Who is the sender, as the recipient would see them.
  let senderName = company;
  if (senderIsSeeker) { const { data: sp } = await admin.from("profiles").select("full_name").eq("id", msg.sender_id).single(); senderName = sp?.full_name || "A candidate"; }

  const { data: ru } = await admin.auth.admin.getUserById(recipientId);
  const to = ru?.user?.email;
  if (to) {
    const preview = esc(String(msg.body || "").slice(0, 140));
    const html = `<div style="font-family:Inter,Arial,sans-serif;max-width:520px;margin:0 auto;color:#20242c;">
      <div style="font-family:Georgia,serif;font-size:22px;font-weight:600;color:#ff5a3c;margin-bottom:16px;">GigCute</div>
      <p style="font-size:15px;line-height:1.5;"><b>${esc(senderName)}</b> sent you a message about <b>${esc(role)}</b>.</p>
      <p style="font-size:14px;color:#555;border-left:3px solid #eee;padding-left:12px;">${preview}</p>
      <p style="margin-top:20px;"><a href="${APP}/messages" style="background:#ff5a3c;color:#fff;text-decoration:none;padding:11px 20px;border-radius:10px;font-weight:600;">Reply on GigCute →</a></p>
      <p style="font-size:12px;color:#9aa;margin-top:24px;">Turn these off anytime in Settings &amp; privacy → Notifications.</p></div>`;
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${Deno.env.get("RESEND_API_KEY")}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: FROM, to: [to], subject: `${senderName} messaged you — ${role}`, html }),
    });
    if (!r.ok) console.warn("resend", r.status, await r.text());
  }
  await admin.from("message_notify_state").upsert({ conversation_id: msg.conversation_id, recipient_id: recipientId, last_email_at: new Date().toISOString() });
  return json({ ok: true });
});
