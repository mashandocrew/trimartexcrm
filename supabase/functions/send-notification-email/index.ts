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

import { createClient } from "jsr:@supabase/supabase-js@2";

Deno.serve(async (_req: Request) => {
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const resendKey = Deno.env.get("RESEND_API_KEY");
    const fromEmail = Deno.env.get("RESEND_FROM_EMAIL") || "Trimartex CRM <onboarding@resend.dev>";

    if (!resendKey) {
      return new Response(
        JSON.stringify({ skipped: true, reason: "RESEND_API_KEY no configurada" }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }

    const supabase = createClient(supabaseUrl, serviceKey);

    const { data: pending, error } = await supabase
      .from("notificaciones")
      .select("id, destinatario_email, titulo, mensaje")
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
