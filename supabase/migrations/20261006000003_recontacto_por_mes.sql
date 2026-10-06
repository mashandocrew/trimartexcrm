-- Trimartex CRM — Recontacto "Por mes".
--
-- Algunos leads piden que se los vuelva a llamar en un mes puntual
-- ("hablame en diciembre"). Esos leads quedan con recontacto_active = true
-- (así salen del pipeline igual que Recontacto) pero estacionados en la
-- página "Por mes" en vez de en las 8 semanas: no vencen semana a semana y
-- recién avisan cuando llega el mes pedido.
--
--  - recontacto_mes: primer día del mes pedido (null = ciclo semanal normal).
--  - recontacto_mes_motivo: por qué pidió ese mes ("cierra el balance").
--  - trg_leads_recontacto_next_date(): al volver del mes al ciclo semanal el
--    vencimiento arranca de nuevo desde hoy (si no, quedaría la fecha vieja
--    y el lead aparecería vencido apenas vuelve a Semana 1).
--  - generar_notificaciones(): los leads con mes no generan "Seguimiento
--    vencido"; en su lugar, el día 1 del mes pedido (o el primer ciclo
--    después) se crea un aviso "recontacto_mes", una sola vez por mes pedido.
--  - trg_leads_audit(): deja asentado en el historial cuando se agenda o se
--    quita el mes.

alter table public.leads
  add column if not exists recontacto_mes date;
alter table public.leads_privados_tristan
  add column if not exists recontacto_mes date;
alter table public.leads
  add column if not exists recontacto_mes_motivo text;
alter table public.leads_privados_tristan
  add column if not exists recontacto_mes_motivo text;

create or replace function public.trg_leads_recontacto_next_date()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.recontacto_active then
      new.recontacto_next_date = current_date + 7;
    end if;
    return new;
  end if;

  if new.recontacto_active and (
    not old.recontacto_active
    or old.recontacto_stage is distinct from new.recontacto_stage
    or (old.recontacto_mes is not null and new.recontacto_mes is null)
  ) then
    new.recontacto_next_date = current_date + 7;
  elsif not new.recontacto_active and old.recontacto_active then
    new.recontacto_next_date = null;
  end if;

  -- Fuera de Recontacto no tiene sentido conservar un mes agendado.
  if not new.recontacto_active then
    new.recontacto_mes = null;
    new.recontacto_mes_motivo = null;
  end if;

  return new;
end;
$$;

create or replace function public.mes_label(d date)
returns text
language sql
immutable
set search_path = public
as $$
  select (array['Enero','Febrero','Marzo','Abril','Mayo','Junio','Julio',
                'Agosto','Septiembre','Octubre','Noviembre','Diciembre'])[extract(month from d)::int]
         || ' ' || extract(year from d)::int;
$$;

create or replace function public.trg_leads_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.lead_history (lead_id, label, created_by)
    values (new.id, 'Lead creado', auth.uid());
    return new;
  end if;

  -- tg_op = 'UPDATE'
  if old.etapa is distinct from new.etapa then
    insert into public.lead_history (lead_id, label, created_by)
    values (
      new.id,
      case when new.etapa = 'cotizacion_enviada'
        then 'Presupuesto enviado'
        else 'Cambió a ' || public.etapa_label(new.etapa)
      end,
      auth.uid()
    );
  end if;

  if old.cierre is distinct from new.cierre then
    insert into public.lead_history (lead_id, label, created_by)
    values (
      new.id,
      case
        when new.cierre = 'cerrado' then 'Marcado como Cerrado'
        when new.cierre = 'no_cerrado' then 'Marcado como No cerrado'
        else 'Estado de cierre sin definir'
      end,
      auth.uid()
    );
  end if;

  if old.recontacto_active is distinct from new.recontacto_active then
    insert into public.lead_history (lead_id, label, created_by)
    values (
      new.id,
      case
        when new.recontacto_active and new.recontacto_mes is not null
          then 'Agendado para ' || public.mes_label(new.recontacto_mes)
        when new.recontacto_active
          then 'Enviado a Recontacto (semana ' || new.recontacto_stage || ')'
        else 'Sacado de Recontacto'
      end,
      auth.uid()
    );
  elsif new.recontacto_active and old.recontacto_mes is distinct from new.recontacto_mes then
    insert into public.lead_history (lead_id, label, created_by)
    values (
      new.id,
      case when new.recontacto_mes is not null
        then 'Agendado para ' || public.mes_label(new.recontacto_mes)
        else 'Recontacto: vuelve al ciclo semanal (semana ' || new.recontacto_stage || ')'
      end,
      auth.uid()
    );
  elsif new.recontacto_active and old.recontacto_stage is distinct from new.recontacto_stage then
    insert into public.lead_history (lead_id, label, created_by)
    values (new.id, 'Recontacto: semana ' || new.recontacto_stage, auth.uid());
  end if;

  return new;
end;
$$;

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

  -- 1) Seguimiento vencido — pipeline compartido, ambos roles. Los leads
  --    agendados para un mes no vencen semana a semana.
  insert into notificaciones (destinatario_email, tipo, lead_id, titulo, mensaje)
  select r.email, 'seguimiento_vencido', l.id,
         'Seguimiento vencido: ' || l.empresa,
         'El recontacto semana ' || l.recontacto_stage || '/8 de "' || l.empresa || '" venció el ' || to_char(l.recontacto_next_date, 'DD/MM/YYYY') || '.'
  from leads l
  cross join (values (v_joaquin_email), (v_tristan_email)) as r(email)
  left join preferencias_notificacion pn on pn.email = r.email
  where l.trashed_at is null and not l.archived
    and l.recontacto_active and l.recontacto_mes is null
    and l.recontacto_next_date < current_date
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
    and l.recontacto_active and l.recontacto_mes is null
    and l.recontacto_next_date < current_date
    and not ('seguimiento_vencido' = any(coalesce(pn.tipos_mute, '{}')))
    and not (coalesce(l.clasificacion_abc::text, 'sin') = any(coalesce(pn.abc_mute, '{}')))
    and not exists (
      select 1 from notificaciones n
      where n.lead_privado_id = l.id and n.destinatario_email = v_tristan_email
        and n.tipo = 'seguimiento_vencido'
        and n.created_at >= l.recontacto_next_date
    );

  -- 3) Sin movimiento hace demasiados días — pipeline compartido, ambos roles.
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

  -- 6) Llegó el mes pedido — pipeline compartido, ambos roles. Una sola vez
  --    por mes agendado: si se re-agenda para otro mes, es un evento nuevo.
  insert into notificaciones (destinatario_email, tipo, lead_id, titulo, mensaje)
  select r.email, 'recontacto_mes', l.id,
         'Hablar este mes: ' || l.empresa,
         '"' || l.empresa || '" pidió que lo contacten en ' || public.mes_label(l.recontacto_mes)
           || coalesce(' (' || nullif(l.recontacto_mes_motivo, '') || ')', '') || '.'
  from leads l
  cross join (values (v_joaquin_email), (v_tristan_email)) as r(email)
  left join preferencias_notificacion pn on pn.email = r.email
  where l.trashed_at is null and not l.archived
    and l.recontacto_active and l.recontacto_mes <= current_date
    and r.email is not null
    and not ('recontacto_mes' = any(coalesce(pn.tipos_mute, '{}')))
    and not (coalesce(l.clasificacion_abc::text, 'sin') = any(coalesce(pn.abc_mute, '{}')))
    and not exists (
      select 1 from notificaciones n
      where n.lead_id = l.id and n.destinatario_email = r.email
        and n.tipo = 'recontacto_mes'
        and n.created_at >= l.recontacto_mes
    );

  -- 7) Llegó el mes pedido — Gestión Privada, solo Tristán.
  insert into notificaciones (destinatario_email, tipo, lead_privado_id, titulo, mensaje)
  select v_tristan_email, 'recontacto_mes', l.id,
         'Hablar este mes: ' || l.empresa,
         '"' || l.empresa || '" (Gestión Privada) pidió que lo contacten en ' || public.mes_label(l.recontacto_mes)
           || coalesce(' (' || nullif(l.recontacto_mes_motivo, '') || ')', '') || '.'
  from leads_privados_tristan l
  left join preferencias_notificacion pn on pn.email = v_tristan_email
  where v_tristan_email is not null
    and l.trashed_at is null and not l.archived
    and l.recontacto_active and l.recontacto_mes <= current_date
    and not ('recontacto_mes' = any(coalesce(pn.tipos_mute, '{}')))
    and not (coalesce(l.clasificacion_abc::text, 'sin') = any(coalesce(pn.abc_mute, '{}')))
    and not exists (
      select 1 from notificaciones n
      where n.lead_privado_id = l.id and n.destinatario_email = v_tristan_email
        and n.tipo = 'recontacto_mes'
        and n.created_at >= l.recontacto_mes
    );
end;
$$;

-- El tipo nuevo tiene que estar en la lista permitida de notificaciones
-- (si no, el insert falla y aborta todo el ciclo diario del generador).
alter table public.notificaciones drop constraint notificaciones_tipo_check;
alter table public.notificaciones add constraint notificaciones_tipo_check
  check (tipo = any (array['seguimiento_vencido','sin_movimiento','recordatorio_manual','recordatorio_automatico','lead_compartido','lead_devuelto','recontacto_mes']));
