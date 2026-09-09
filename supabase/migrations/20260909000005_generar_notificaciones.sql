-- Trimartex CRM — generación diaria de notificaciones automáticas y disparo
-- de recordatorios vencidos.
--
-- Decisión de enrutamiento (no estaba en el gate original, documentada acá
-- para que quede explícita y sea fácil de ajustar): las alertas del pipeline
-- COMPARTIDO (leads) van a AMBOS roles, porque ambos ya ven y operan esas
-- filas por igual según la RLS existente. Las alertas de la GESTIÓN PRIVADA
-- de Tristán (leads_privados_tristan) son 100% privadas — solo a Tristán —
-- consistente con la decisión del Sr. en el gate de la Etapa 2.
--
-- No duplica: no inserta una notificación nueva de un tipo/lead/destinatario
-- si ya hay una sin leer de ese mismo tipo para ese mismo lead y destinatario.

create extension if not exists pg_net with schema extensions;

create or replace function public.generar_notificaciones()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_joaquin_email text;
  v_tristan_email text;
  v_joaquin_dias int;
  v_tristan_dias int;
begin
  select email into v_joaquin_email from usuarios_autorizados where rol = 'joaquin' limit 1;
  select email into v_tristan_email from usuarios_autorizados where rol = 'tristan' limit 1;
  v_joaquin_dias := coalesce((select dias_sin_seguimiento from preferencias_notificacion where email = v_joaquin_email), 3);
  v_tristan_dias := coalesce((select dias_sin_seguimiento from preferencias_notificacion where email = v_tristan_email), 3);

  -- 1) Seguimiento vencido (recontacto_next_date ya pasó) — pipeline compartido, ambos roles.
  insert into notificaciones (destinatario_email, tipo, lead_id, titulo, mensaje)
  select r.email, 'seguimiento_vencido', l.id,
         'Seguimiento vencido: ' || l.empresa,
         'El recontacto semana ' || l.recontacto_stage || '/8 de "' || l.empresa || '" venció el ' || to_char(l.recontacto_next_date, 'DD/MM/YYYY') || '.'
  from leads l
  cross join (values (v_joaquin_email), (v_tristan_email)) as r(email)
  where l.trashed_at is null and not l.archived
    and l.recontacto_active and l.recontacto_next_date < current_date
    and r.email is not null
    and not exists (
      select 1 from notificaciones n
      where n.lead_id = l.id and n.destinatario_email = r.email
        and n.tipo = 'seguimiento_vencido' and not n.leida
    );

  -- 2) Seguimiento vencido — Gestión Privada de Tristán, solo Tristán.
  insert into notificaciones (destinatario_email, tipo, lead_privado_id, titulo, mensaje)
  select v_tristan_email, 'seguimiento_vencido', l.id,
         'Seguimiento vencido: ' || l.empresa,
         'El recontacto semana ' || l.recontacto_stage || '/8 de "' || l.empresa || '" (Gestión Privada) venció el ' || to_char(l.recontacto_next_date, 'DD/MM/YYYY') || '.'
  from leads_privados_tristan l
  where v_tristan_email is not null
    and l.trashed_at is null and not l.archived
    and l.recontacto_active and l.recontacto_next_date < current_date
    and not exists (
      select 1 from notificaciones n
      where n.lead_privado_id = l.id and n.destinatario_email = v_tristan_email
        and n.tipo = 'seguimiento_vencido' and not n.leida
    );

  -- 3) Sin movimiento hace demasiados días — pipeline compartido, ambos roles
  --    (cada uno con su propio umbral configurado en preferencias_notificacion).
  insert into notificaciones (destinatario_email, tipo, lead_id, titulo, mensaje)
  select r.email, 'sin_movimiento', l.id,
         'Sin novedades: ' || l.empresa,
         '"' || l.empresa || '" no tiene movimientos desde el ' || to_char(l.updated_at, 'DD/MM/YYYY') || '.'
  from leads l
  cross join (values (v_joaquin_email, v_joaquin_dias), (v_tristan_email, v_tristan_dias)) as r(email, dias)
  where l.trashed_at is null and not l.archived and not l.recontacto_active
    and l.etapa <> 'cerrado'
    and r.email is not null
    and l.updated_at < now() - (r.dias || ' days')::interval
    and not exists (
      select 1 from notificaciones n
      where n.lead_id = l.id and n.destinatario_email = r.email
        and n.tipo = 'sin_movimiento' and not n.leida
    );

  -- 4) Sin movimiento hace demasiados días — Gestión Privada, solo Tristán.
  insert into notificaciones (destinatario_email, tipo, lead_privado_id, titulo, mensaje)
  select v_tristan_email, 'sin_movimiento', l.id,
         'Sin novedades: ' || l.empresa,
         '"' || l.empresa || '" (Gestión Privada) no tiene movimientos desde el ' || to_char(l.updated_at, 'DD/MM/YYYY') || '.'
  from leads_privados_tristan l
  where v_tristan_email is not null
    and l.trashed_at is null and not l.archived and not l.recontacto_active
    and l.etapa <> 'cerrado'
    and l.updated_at < now() - (v_tristan_dias || ' days')::interval
    and not exists (
      select 1 from notificaciones n
      where n.lead_privado_id = l.id and n.destinatario_email = v_tristan_email
        and n.tipo = 'sin_movimiento' and not n.leida
    );

  -- 5) Recordatorios (manuales o automáticos) que llegaron a su fecha_disparo.
  insert into notificaciones (destinatario_email, tipo, lead_id, lead_privado_id, titulo, mensaje)
  select rec.creado_por_email,
         case rec.tipo when 'manual' then 'recordatorio_manual' else 'recordatorio_automatico' end,
         rec.lead_id, rec.lead_privado_id,
         'Recordatorio: ' || coalesce(l1.empresa, l2.empresa, ''),
         coalesce(nullif(rec.mensaje, ''), 'Tenías un recordatorio pendiente.')
  from recordatorios rec
  left join leads l1 on l1.id = rec.lead_id
  left join leads_privados_tristan l2 on l2.id = rec.lead_privado_id
  where not rec.disparado and rec.fecha_disparo <= now();

  update recordatorios set disparado = true where not disparado and fecha_disparo <= now();
end;
$$;

revoke execute on function public.generar_notificaciones() from public, anon, authenticated;

select cron.schedule(
  'trimartex-generar-notificaciones',
  '0 9 * * *', -- 06:00 America/Argentina (UTC-3), todos los días
  $$select public.generar_notificaciones();$$
);

-- Dispara el edge function send-notification-email cada 15 minutos: revisa
-- notificaciones.email_enviado = false y manda por Resend las que el
-- destinatario tenga habilitadas por canal_email. Se autentica con la anon
-- key (clave pública, segura de embeber acá) para pasar verify_jwt; adentro,
-- el edge function usa su propio SUPABASE_SERVICE_ROLE_KEY (inyectada
-- automáticamente por Supabase, nunca vista por esta migración) para leer
-- todas las notificaciones pendientes sin las restricciones de RLS.
select cron.schedule(
  'trimartex-enviar-notificaciones-email',
  '*/15 * * * *',
  $$
  select net.http_post(
    url := 'https://yvjxftmfjoxajjryxabo.supabase.co/functions/v1/send-notification-email',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inl2anhmdG1mam94YWpqcnl4YWJvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODg4MDYyMDMsImV4cCI6MjEwNDM4MjIwM30.Sw2Y69O3FEzqwUFv1Ml98dEsP20VQ8SOpdJnSRv1gig'
    ),
    body := '{}'::jsonb
  );
  $$
);
