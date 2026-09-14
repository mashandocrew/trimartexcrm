-- Trimartex CRM — configuración avanzada de notificaciones por perfil.
--
-- A pedido del Sr.: cada usuario (JP/Tristán) va a poder, además de lo que ya
-- tenía (canal in-app, canal email, umbral de días por etapa):
--   1. Silenciar tipos de aviso puntuales (ej. no quiero "lead_compartido").
--   2. Filtrar por prioridad ABC qué avisos se generan — corte de raíz, no
--      solo un cambio de umbral: si C está filtrada, ese aviso ni se crea.
--   3. Ajustar el umbral de "sin movimiento" según la prioridad ABC del lead
--      (ej. avisar antes para A, con más margen para C) — un offset en días
--      sobre el umbral por etapa ya existente, no una matriz completa
--      etapa×ABC (esa matriz infla la UI sin necesidad real).
--   4. Un canal más, independiente de canal_inapp/canal_email: canal_toast,
--      para el cartel emergente estilo macOS (ver commit de UI aparte).
--   5. Compartir la propia bandeja (solo lectura) con el otro perfil.
--      Decisión del Sr.: un solo sentido — Joaquín puede prender un
--      interruptor para que Tristán vea sus notificaciones; no hay
--      interruptor equivalente en el sentido inverso.
--
-- abc_mute/ajuste_dias_abc usan la clave 'sin' para leads todavía sin
-- clasificación ABC cargada (clasificacion_abc is null) — no quedan afuera
-- del sistema de filtros solo por no tener ABC cargado todavía.

alter table public.preferencias_notificacion
  add column canal_toast boolean not null default true,
  add column tipos_mute text[] not null default '{}',
  add column abc_mute text[] not null default '{}',
  add column ajuste_dias_abc jsonb not null default '{}'::jsonb,
  add column compartir_con_otro boolean not null default false;

alter table public.preferencias_notificacion
  add constraint tipos_mute_valores check (
    tipos_mute <@ array['seguimiento_vencido','sin_movimiento','recordatorio_manual','recordatorio_automatico','lead_compartido']::text[]
  ),
  add constraint abc_mute_valores check (
    abc_mute <@ array['A','B','C','sin']::text[]
  );

-- Devuelve el email de Joaquín solo si él activó compartir_con_otro (si no,
-- null). Tiene que ser security definer: usuarios_autorizados y
-- preferencias_notificacion ya tienen su propia RLS ("leer solo mi fila"),
-- así que una policy de otra tabla que las consultara directamente (sin
-- pasar por una función que bypasee esa RLS) siempre daría cero filas para
-- Tristán — el mismo motivo por el que ya existían is_tristan() /
-- is_authorized_user() como funciones aparte en vez de EXISTS inline.
create or replace function public.notif_email_compartido()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select u.email
  from public.usuarios_autorizados u
  join public.preferencias_notificacion pn on pn.email = u.email
  where u.rol = 'joaquin' and pn.compartir_con_otro
  limit 1;
$$;

revoke execute on function public.notif_email_compartido() from public, anon;
grant execute on function public.notif_email_compartido() to authenticated;

-- Tristán puede ver (solo lectura — nunca marcar leída ni borrar, eso lo
-- filtra el frontend) la bandeja de Joaquín cuando éste activó
-- compartir_con_otro. No hace falta una policy para el sentido inverso: no
-- se pidió.
create policy "notificaciones select compartidas de joaquin"
  on public.notificaciones for select
  to authenticated
  using (
    public.is_tristan()
    and destinatario_email = public.notif_email_compartido()
  );

-- Antes no había forma de borrar una notificación puntual, solo marcarla
-- leída — a pedido del Sr., cada quien puede borrar las propias (nunca las
-- ajenas: esta policy no cubre la bandeja compartida de arriba).
create policy "notificaciones delete own"
  on public.notificaciones for delete
  to authenticated
  using (destinatario_email = (select auth.jwt() ->> 'email'));

-- Para que el frontend de Tristán sepa si mostrar el toggle "Ver las de
-- Joaquín" (y de dónde sacar su email para la consulta de arriba), llama a
-- notif_email_compartido() por RPC — no necesita leer la fila de
-- preferencias_notificacion de Joaquín directamente, así que no hace falta
-- una policy de select nueva ahí: el resto de sus preferencias (umbrales,
-- canales) siguen siendo 100% privadas.

-- generar_notificaciones(): además del umbral por etapa que ya tenía, ahora
-- respeta tipos_mute, abc_mute y el offset de ajuste_dias_abc de cada
-- destinatario. Los joins a preferencias_notificacion son left join con
-- coalesce (no inner): si algún día existiera un usuario autorizado sin fila
-- de preferencias todavía, sus alertas se siguen generando sin filtro en vez
-- de desaparecer en silencio.
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
        and n.tipo = 'seguimiento_vencido' and not n.leida
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
        and n.tipo = 'seguimiento_vencido' and not n.leida
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
        and n.tipo = 'sin_movimiento' and not n.leida
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
        and n.tipo = 'sin_movimiento' and not n.leida
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

revoke execute on function public.generar_notificaciones() from public, anon, authenticated;

-- compartir_lead_tristan(): el aviso a Joaquín de "Tristán compartió un
-- lead" es tipo lead_compartido — si Joaquín lo silenció, respeta lo mismo
-- que generar_notificaciones() para los demás tipos.
create or replace function public.compartir_lead_tristan(p_lead_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new_id uuid;
  v_empresa text;
  v_joaquin_email text;
  v_tipos_mute text[];
begin
  if not public.is_tristan() then
    raise exception 'Solo Tristán puede compartir leads de su Gestión Privada';
  end if;

  insert into public.leads (
    empresa, contacto, telefono, rubro, ticket, fuente, fecha_contacto,
    resultado, notas, etapa, archived, cierre, recontacto_active,
    recontacto_stage, recontacto_next_date, created_by
  )
  select
    empresa, contacto, telefono, rubro, ticket, fuente, fecha_contacto,
    resultado, notas, 'leads_tristan', archived, cierre, recontacto_active,
    recontacto_stage, recontacto_next_date, created_by
  from public.leads_privados_tristan
  where id = p_lead_id
    and trashed_at is null
  returning id, empresa into v_new_id, v_empresa;

  if v_new_id is null then
    raise exception 'Lead privado % no encontrado', p_lead_id;
  end if;

  delete from public.leads_privados_tristan where id = p_lead_id;

  select email into v_joaquin_email from public.usuarios_autorizados where rol = 'joaquin' limit 1;
  if v_joaquin_email is not null then
    select tipos_mute into v_tipos_mute from public.preferencias_notificacion where email = v_joaquin_email;
    if not ('lead_compartido' = any(coalesce(v_tipos_mute, '{}'))) then
      insert into public.notificaciones (destinatario_email, tipo, lead_id, titulo, mensaje)
      values (
        v_joaquin_email, 'lead_compartido', v_new_id,
        'Tristán compartió un lead',
        'Tristán compartió "' || v_empresa || '" con vos — ya está en la columna Leads Tristán.'
      );
    end if;
  end if;

  return v_new_id;
end;
$$;
