// Trimartex CRM — envía por email las notificaciones pendientes (email_enviado
// = false) usando Resend. Invocado cada 15 minutos por el cron job
// trimartex-enviar-notificaciones-email (ver
// 20260909000005_generar_notificaciones.sql).
//
// RESEND_API_KEY es un secret que hay que configurar a mano en el dashboard
// de Supabase (Project Settings → Edge Functions → Secrets) — no lo puede
// setear esta migración ni ningún tooling automático. Sin esa key, esta
// función simplemente no manda nada (respuesta 200 con skipped:true) y las
// notificaciones in-app siguen funcionando igual; no rompe nada por su
// ausencia, pero no llegan emails hasta que se configure.
//
// SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY las inyecta Supabase
// automáticamente en todo edge function — nunca hace falta configurarlas ni
// pasarlas por acá.
//
// CRM_APP_URL (opcional): si se configura, el email incluye un botón
// "Ver en el CRM" apuntando ahí. Sin ella, el email igual funciona, solo sin
// el botón.

import { createClient } from "jsr:@supabase/supabase-js@2";

// Metadata visual por tipo de notificación: color de acento + etiqueta legible,
// usado en el pill del email (ver buildEmailHtml).
const TIPO_META: Record<string, { label: string; color: string }> = {
  seguimiento_vencido: { label: "Seguimiento vencido", color: "#ff453a" },
  sin_movimiento: { label: "Sin novedades", color: "#8e8e93" },
  recordatorio_manual: { label: "Recordatorio", color: "#0a84ff" },
  recordatorio_automatico: { label: "Recordatorio", color: "#0a84ff" },
  lead_compartido: { label: "Lead compartido", color: "#30d158" },
};

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function buildEmailHtml(n: { tipo: string; titulo: string; mensaje: string }, crmUrl?: string): string {
  const meta = TIPO_META[n.tipo] || { label: "Notificación", color: "#0a84ff" };
  const boton = crmUrl
    ? `<tr><td style="padding-top:24px;">
         <a href="${escapeHtml(crmUrl)}" style="display:inline-block;background:#0a84ff;color:#ffffff;text-decoration:none;font-size:14px;font-weight:600;padding:10px 20px;border-radius:8px;">Ver en el CRM</a>
       </td></tr>`
    : "";

  return `<!doctype html>
<html>
  <body style="margin:0;padding:0;background:#f2f2f7;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f2f2f7;padding:32px 16px;">
      <tr>
        <td align="center">
          <table role="presentation" width="480" cellpadding="0" cellspacing="0" style="max-width:480px;width:100%;background:#ffffff;border-radius:16px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,0.08);">
            <tr>
              <td style="padding:24px 28px 0 28px;">
                <span style="font-size:12px;font-weight:600;letter-spacing:0.02em;color:#8e8e93;text-transform:uppercase;">Trimartex CRM</span>
              </td>
            </tr>
            <tr>
              <td style="padding:12px 28px 0 28px;">
                <span style="display:inline-block;background:${meta.color}1a;color:${meta.color};font-size:12px;font-weight:600;padding:4px 10px;border-radius:100px;">${escapeHtml(meta.label)}</span>
              </td>
            </tr>
            <tr>
              <td style="padding:12px 28px 0 28px;">
                <h1 style="margin:0;font-size:19px;line-height:1.35;color:#1c1c1e;font-weight:700;">${escapeHtml(n.titulo)}</h1>
              </td>
            </tr>
            <tr>
              <td style="padding:10px 28px 0 28px;">
                <p style="margin:0;font-size:15px;line-height:1.5;color:#3a3a3c;">${escapeHtml(n.mensaje)}</p>
              </td>
            </tr>
            ${boton}
            <tr>
              <td style="padding:28px 28px 24px 28px;">
                <hr style="border:none;border-top:1px solid #e5e5ea;margin:0 0 16px 0;" />
                <p style="margin:0;font-size:12px;line-height:1.5;color:#aeaeb2;">
                  Recibiste este email porque tenés activados los recordatorios de seguimiento en el CRM de Trimartex.
                  Podés desactivarlos desde Configuración → Notificaciones.
                </p>
              </td>
            </tr>
          </table>
        </td>
      </tr>
    </table>
  </body>
</html>`;
}

Deno.serve(async (_req: Request) => {
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const resendKey = Deno.env.get("RESEND_API_KEY");
    const fromEmail = Deno.env.get("RESEND_FROM_EMAIL") || "Trimartex CRM <onboarding@resend.dev>";
    const crmUrl = Deno.env.get("CRM_APP_URL");

    if (!resendKey) {
      return new Response(
        JSON.stringify({ skipped: true, reason: "RESEND_API_KEY no configurada" }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }

    const supabase = createClient(supabaseUrl, serviceKey);

    const { data: pending, error } = await supabase
      .from("notificaciones")
      .select("id, destinatario_email, tipo, titulo, mensaje")
      .eq("email_enviado", false)
      .order("created_at", { ascending: true })
      .limit(200);

    if (error) throw error;
    if (!pending || pending.length === 0) {
      return new Response(JSON.stringify({ sent: 0 }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    const { data: prefs } = await supabase
      .from("preferencias_notificacion")
      .select("email, canal_email");
    const canalEmailPorUsuario = new Map((prefs || []).map((p) => [p.email, p.canal_email]));

    let sent = 0;
    const processedIds: string[] = [];

    for (const n of pending) {
      // Sin fila de preferencias todavía = tratar el email como habilitado (default).
      const canalEmail = canalEmailPorUsuario.has(n.destinatario_email)
        ? canalEmailPorUsuario.get(n.destinatario_email)
        : true;

      if (!canalEmail) {
        processedIds.push(n.id);
        continue;
      }

      const res = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${resendKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          from: fromEmail,
          to: n.destinatario_email,
          subject: n.titulo,
          html: buildEmailHtml(n, crmUrl),
          text: n.mensaje,
        }),
      });

      if (res.ok) {
        sent++;
        processedIds.push(n.id);
      } else {
        console.error("Resend error para notificación", n.id, await res.text());
      }
    }

    if (processedIds.length) {
      await supabase.from("notificaciones").update({ email_enviado: true }).in("id", processedIds);
    }

    return new Response(JSON.stringify({ sent, total: pending.length }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error(e);
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
