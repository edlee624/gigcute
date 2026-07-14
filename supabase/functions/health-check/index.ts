// ============================================================================
// GigCute — health-check: daily ops report so failures never go unnoticed again
// (the posting-expiry cron failed silently for days before the audit caught it).
// Pulls health_report() (service-role-only RPC, migration 0070) and emails a
// summary via Resend. The subject flips to an alert when something needs eyes:
// cron failures, a stalled ingest, or a 5xx spike.
//
// Protected by the same x-cron-secret header as ingest-jobs. Deploy:
//   supabase functions deploy health-check --project-ref ztvirfxxyvvcrxcjstzi --no-verify-jwt
// The daily cron (12:00 UTC ≈ 8am ET) is scheduled directly in pg_cron — NOT in a
// migration, so the secret never lands in the repo (jobname: daily-health-check).
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (auto), RESEND_API_KEY, CRON_SECRET,
//      HEALTH_EMAIL (default gigcutesite@gmail.com)
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FROM = Deno.env.get("MAIL_FROM") || "GigCute <noreply@gigcute.com>";
const TO = Deno.env.get("HEALTH_EMAIL") || "gigcutesite@gmail.com";

Deno.serve(async (req) => {
  if ((req.headers.get("x-cron-secret") || "") !== Deno.env.get("CRON_SECRET")) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: { "content-type": "application/json" } });
  }
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: h, error } = await admin.rpc("health_report");
  if (error || !h) {
    return new Response(JSON.stringify({ error: String(error?.message || "no report") }), { status: 500, headers: { "content-type": "application/json" } });
  }

  const cronFails: Array<{ job: string; status: string; at: string; msg: string }> = h.cron_failures_24h || [];
  const alerts: string[] = [];
  if (cronFails.length) alerts.push(`${cronFails.length} cron failure(s)`);
  if ((h.jobs_24h ?? 0) === 0) alerts.push("ingest stalled (0 jobs in 24h)");
  if ((h.http_5xx_24h ?? 0) > 50) alerts.push(`${h.http_5xx_24h} HTTP 5xx in 24h`);

  const subject = alerts.length
    ? `⚠ GigCute health: ${alerts.join(" · ")}`
    : `✓ GigCute health: all clear`;

  const row = (k: string, v: unknown) =>
    `<tr><td style="padding:4px 14px 4px 0;color:#666;">${k}</td><td style="padding:4px 0;font-weight:600;">${v}</td></tr>`;
  const failHtml = cronFails.length
    ? `<h3 style="color:#c0392b;">Cron failures (24h)</h3><ul>` +
      cronFails.map((f) => `<li><b>${f.job}</b> — ${f.status} at ${f.at}<br><code>${f.msg || ""}</code></li>`).join("") + `</ul>`
    : "";
  const html = `
    <div style="font-family:system-ui,sans-serif;font-size:14px;color:#222;max-width:560px;">
      <h2 style="margin:0 0 4px;">GigCute daily health</h2>
      <div style="color:${alerts.length ? "#c0392b" : "#2e7d4f"};font-weight:600;margin-bottom:14px;">
        ${alerts.length ? alerts.join(" · ") : "All systems normal"}</div>
      <table style="border-collapse:collapse;">
        ${row("Database size", h.db_size)}
        ${row("Jobs (total / active)", `${h.jobs_total} / ${h.jobs_active}`)}
        ${row("Jobs ingested (24h)", h.jobs_24h)}
        ${row("Users (total / new 24h)", `${h.users_total} / ${h.users_24h}`)}
        ${row("HTTP 5xx (24h)", h.http_5xx_24h)}
      </table>
      ${failHtml}
    </div>`;

  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${Deno.env.get("RESEND_API_KEY")}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to: [TO], subject, html }),
  });
  return new Response(JSON.stringify({ ok: r.ok, alerts }), { headers: { "content-type": "application/json" } });
});
