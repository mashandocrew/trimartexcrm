-- Trimartex CRM — las notificaciones leídas o eliminadas no vuelven a aparecer.
--
-- Bug: generar_notificaciones() (cron diario 09:00) solo evitaba duplicar si
-- ya había una notificación NO leída del mismo lead/tipo. Apenas el usuario
-- la marcaba leída o la borraba, al día siguiente se volvía a crear idéntica
-- (Joaquín llegó a tener 39 "Sin novedades" leídas repetidas para 20 leads).
--
-- Arreglo:
--  1) "Eliminar" pasa a ser borrado lógico (columna eliminada): la fila queda
--     como marca de "ya avisado" para el generador, pero el frontend no la
--     muestra nunca más.
--  2) El generador deduplica contra CUALQUIER notificación del mismo evento
--     (leída, no leída o eliminada):
--     - seguimiento_vencido: ya existe una creada desde el vencimiento actual
--       (recontacto_next_date). Si el lead avanza de semana y vuelve a
--       vencer, es un evento nuevo y se avisa de nuevo.
--     - sin_movimiento: ya existe una creada después del último movimiento
--       (updated_at). Si el lead se toca y vuelve a quedar quieto, se avisa
--       de nuevo.

alter table public.notificaciones
  add column if not exists eliminada boolean not null default false;

grant update (leida, eliminada) on public.notificaciones to authenticated;

create index if not exists notificaciones_dedupe_lead_idx
  on public.notificaciones (lead_id, destinatario_email, tipo, created_at);
create index if not exists notificaciones_dedupe_privado_idx
  on public.notificaciones (lead_privado_id, destinatario_email, tipo, created_at);

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
  left join preferencias_notificacion pn on pn.email = r.email
  where l.trashed_at is null and not l.archived
    and l.recontacto_active and l.recontacto_next_date < current_date
    and r.email is not null
    and not ('seguimiento_vencido' = any(coalesce(pn.tipos_mute, '{}')))
    and not (coalesce(l.clasificacion_abc::text, 'sin') = any(coalesce(pn.abc_mute, '{}')))
    and not exists (
      select 1 from notificaciones n
      where n.lead_id = l.id and n.destinatario_email = r.email
        and n.tipo = 'seguimiento_vencido'
        and n.created_at >= l.recontacto_next_date
    );

  -- 2) Seguimiento vencido — Gestión Privada de Tristán, solo Tristán.
  insert into notificaciones (destinatario_email, tipo, lead_privado_id, titulo, mensaje)
  select v_tristan_email, 'seguimiento_vencido', l.id,
         'Seguimiento vencido: ' || l.empresa,
         'El recontacto semana ' || l.recontacto_stage || '/8 de "' || l.empresa || '" (Gestión Privada) venció el ' || to_char(l.recontacto_next_date, 'DD/MM/YYYY') || '.'
  from leads_privados_tristan l
  left join preferencias_notificacion pn on pn.email = v_tristan_email
  where v_tristan_email is not null
    and l.trashed_at is null and not l.archived
    and l.recontacto_active and l.recontacto_next_date < current_date
    and not ('seguimiento_vencido' = any(coalesce(pn.tipos_mute, '{}')))
    and not (coalesce(l.clasificacion_abc::text, 'sin') = any(coalesce(pn.abc_mute, '{}')))
    and not exists (
      select 1 from notificaciones n
      where n.lead_privado_id = l.id and n.destinatario_email = v_tristan_email
        and n.tipo = 'seguimiento_vencido'
        and n.created_at >= l.recontacto_next_date
    );

  -- 3) Sin movimiento hace demasiados días — pipeline compartido, ambos roles
  --    (umbral propio por etapa y por destinatario, más el offset por ABC).
  insert into notificaciones (destinatario_email, tipo, lead_id, titulo, mensaje)
  select r.email, 'sin_movimiento', l.id,
         'Sin novedades: ' || l.empresa,
         '"' || l.empresa || '" no tiene movimientos desde el ' || to_char(l.updated_at, 'DD/MM/YYYY') || '.'
  from leads l
  cross join (values (v_joaquin_email), (v_tristan_email)) as r(email)
  left join preferencias_notificacion pn on pn.email = r.email
  where l.trashed_at is null and not l.archived and not l.recontacto_active
    and r.email is not null
    and (pn.dias_por_etapa ->> l.etapa::text) is not null
    and not ('sin_movimiento' = any(coalesce(pn.tipos_mute, '{}')))
    and not (coalesce(l.clasificacion_abc::text, 'sin') = any(coalesce(pn.abc_mute, '{}')))
    and l.updated_at < now() - (
      greatest(0, (pn.dias_por_etapa ->> l.etapa::text)::int
        + coalesce((pn.ajuste_dias_abc ->> coalesce(l.clasificacion_abc::text, 'sin'))::int, 0))::text
      || ' days'
    )::interval
    and not exists (
      select 1 from notificaciones n
      where n.lead_id = l.id and n.destinatario_email = r.email
        and n.tipo = 'sin_movimiento'
        and n.created_at >= l.updated_at
    );

  -- 4) Sin movimiento hace demasiados días — Gestión Privada, solo Tristán.
  insert into notificaciones (destinatario_email, tipo, lead_privado_id, titulo, mensaje)
  select v_tristan_email, 'sin_movimiento', l.id,
         'Sin novedades: ' || l.empresa,
         '"' || l.empresa || '" (Gestión Privada) no tiene movimientos desde el ' || to_char(l.updated_at, 'DD/MM/YYYY') || '.'
  from leads_privados_tristan l
  left join preferencias_notificacion pn on pn.email = v_tristan_email
  where v_tristan_email is not null
    and l.trashed_at is null and not l.archived and not l.recontacto_active
    and (pn.dias_por_etapa ->> l.etapa::text) is not null
    and not ('sin_movimiento' = any(coalesce(pn.tipos_mute, '{}')))
    and not (coalesce(l.clasificacion_abc::text, 'sin') = any(coalesce(pn.abc_mute, '{}')))
    and l.updated_at < now() - (
      greatest(0, (pn.dias_por_etapa ->> l.etapa::text)::int
        + coalesce((pn.ajuste_dias_abc ->> coalesce(l.clasificacion_abc::text, 'sin'))::int, 0))::text
      || ' days'
    )::interval
    and not exists (
      select 1 from notificaciones n
      where n.lead_privado_id = l.id and n.destinatario_email = v_tristan_email
        and n.tipo = 'sin_movimiento'
        and n.created_at >= l.updated_at
    );

  -- 5) Recordatorios (manuales o automáticos) que llegaron a su fecha_disparo.
  --    Respeta tipos_mute y abc_mute de quien creó el recordatorio — si lo
  --    silenció, el recordatorio igual se marca disparado (no vuelve a
  --    evaluarse en el próximo ciclo), solo no genera la notificación.
  insert into notificaciones (destinatario_email, tipo, lead_id, lead_privado_id, titulo, mensaje)
  select rec.creado_por_email,
         case rec.tipo when 'manual' then 'recordatorio_manual' else 'recordatorio_automatico' end,
         rec.lead_id, rec.lead_privado_id,
         'Recordatorio: ' || coalesce(l1.empresa, l2.empresa, ''),
         coalesce(nullif(rec.mensaje, ''), 'Tenías un recordatorio pendiente.')
  from recordatorios rec
  left join leads l1 on l1.id = rec.lead_id
  left join leads_privados_tristan l2 on l2.id = rec.lead_privado_id
  left join preferencias_notificacion pn on pn.email = rec.creado_por_email
  where not rec.disparado and rec.fecha_disparo <= now()
    and not (
      (case rec.tipo when 'manual' then 'recordatorio_manual' else 'recordatorio_automatico' end)
      = any(coalesce(pn.tipos_mute, '{}'))
    )
    and not (coalesce(coalesce(l1.clasificacion_abc, l2.clasificacion_abc)::text, 'sin') = any(coalesce(pn.abc_mute, '{}')));

  update recordatorios set disparado = true where not disparado and fecha_disparo <= now();
end;
$$;

-- Limpieza de los duplicados que ya generó el bug: de cada serie repetida
-- (mismo destinatario/tipo/lead) queda solo la más nueva.
delete from public.notificaciones n
using public.notificaciones m
where n.tipo in ('sin_movimiento', 'seguimiento_vencido')
  and m.tipo = n.tipo
  and m.destinatario_email = n.destinatario_email
  and coalesce(m.lead_id, m.lead_privado_id) = coalesce(n.lead_id, n.lead_privado_id)
  and m.created_at > n.created_at;
