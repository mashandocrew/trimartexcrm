-- Trimartex CRM — alertas de "sin movimiento" configurables por etapa.
--
-- Antes todo el pipeline (y "Cerrado" ni siquiera eso) compartía un único
-- umbral de días ("dias_sin_seguimiento"). A pedido del Sr.: el reloj de
-- "Seguimiento" no es el mismo que el de "Cerrado" (pedido confirmado) —
-- y ninguno de los dos es el reloj de Recontacto, que sigue siendo aparte
-- (fechas explícitas por lead, no "días sin mover", ver
-- trg_leads_recontacto_next_date(), sin cambios acá).
--
-- Reemplaza dias_sin_seguimiento (int) por dias_por_etapa (jsonb), con una
-- entrada por cada etapa del pipeline compartido — incluidas "leads_tristan"
-- y "cerrado", que antes usaban el mismo número que el resto (o, en el caso
-- de "cerrado", no generaban esta alerta nunca). Los valores existentes se
-- migran como punto de partida para todas las etapas de cada usuario, para
-- no resetear en cero lo que ya tenían configurado.

alter table public.preferencias_notificacion
  add column dias_por_etapa jsonb not null default jsonb_build_object(
    'leads_tristan', 2, 'nuevo', 2, 'contactado', 3,
    'cotizacion_pendiente', 3, 'cotizacion_enviada', 5,
    'seguimiento', 5, 'cerrado', 14
  );

update public.preferencias_notificacion
set dias_por_etapa = jsonb_build_object(
  'leads_tristan', dias_sin_seguimiento, 'nuevo', dias_sin_seguimiento,
  'contactado', dias_sin_seguimiento, 'cotizacion_pendiente', dias_sin_seguimiento,
  'cotizacion_enviada', dias_sin_seguimiento, 'seguimiento', dias_sin_seguimiento,
  'cerrado', dias_sin_seguimiento
);

alter table public.preferencias_notificacion drop column dias_sin_seguimiento;

-- generar_notificaciones(): la alerta "sin_movimiento" ahora lee el umbral
-- de dias_por_etapa según la etapa del lead y el destinatario, en vez de
-- un único v_joaquin_dias/v_tristan_dias — y ya no excluye "cerrado".
create or replace function public.generar_notificaciones()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_joaquin_email text;
  v_tristan_email text;
begin
  select email into v_joaquin_email from usuarios_autorizados where rol = 'joaquin' limit 1;
  select email into v_tristan_email from usuarios_autorizados where rol = 'tristan' limit 1;

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
  --    (umbral propio por etapa y por destinatario, en
  --    preferencias_notificacion.dias_por_etapa).
  insert into notificaciones (destinatario_email, tipo, lead_id, titulo, mensaje)
  select r.email, 'sin_movimiento', l.id,
         'Sin novedades: ' || l.empresa,
         '"' || l.empresa || '" no tiene movimientos desde el ' || to_char(l.updated_at, 'DD/MM/YYYY') || '.'
  from leads l
  cross join (values (v_joaquin_email), (v_tristan_email)) as r(email)
  join preferencias_notificacion pn on pn.email = r.email
  where l.trashed_at is null and not l.archived and not l.recontacto_active
    and r.email is not null
    and (pn.dias_por_etapa ->> l.etapa::text) is not null
    and l.updated_at < now() - ((pn.dias_por_etapa ->> l.etapa::text) || ' days')::interval
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
  join preferencias_notificacion pn on pn.email = v_tristan_email
  where v_tristan_email is not null
    and l.trashed_at is null and not l.archived and not l.recontacto_active
    and (pn.dias_por_etapa ->> l.etapa::text) is not null
    and l.updated_at < now() - ((pn.dias_por_etapa ->> l.etapa::text) || ' days')::interval
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
