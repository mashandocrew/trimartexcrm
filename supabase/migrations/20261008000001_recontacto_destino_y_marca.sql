-- Trimartex CRM — sacar leads de Recontacto eligiendo destino (Tristán) y
-- marca "vino de Recontacto".
--
-- Hasta ahora Tristán no podía sacar de Recontacto los leads que están en
-- etapas a cargo de Joaquín (Nuevo / Contactado / En conversación): la RLS de
-- leads le bloquea el UPDATE. Esta migración agrega:
--
--  - viene_de_recontacto (leads y leads_privados_tristan): se prende cuando el
--    lead sale de Recontacto sin cambiar de etapa y se apaga al reactivarlo o
--    cuando alguien abre la ficha (marcar_recontacto_visto). El front la
--    muestra como un punto naranja en la tarjeta.
--  - trg_viene_de_recontacto(): mantiene la marca en cualquier salida de
--    Recontacto (desde el modal, drag, "Pedido confirmado" no la prende porque
--    cambia de etapa).
--  - trg_leads_set_updated_at(): un cambio que toca SOLO la marca no cuenta
--    como movimiento (no pisa updated_at, que usan "sin novedades" y el orden).
--  - sacar_de_recontacto(): security definer. Saca el lead de Recontacto y lo
--    deja en el pipeline compartido o en la Gestión Privada de Tristán (mueve,
--    no copia), en la etapa en la que estaba antes de Recontacto (la etapa no
--    se toca al entrar a Recontacto, así que es la etapa actual); si no hay
--    una válida cae en 'nuevo'. Patrón de compartir_lead_tristan() /
--    devolver_lead_tristan() (20260928000002).
--  - marcar_recontacto_visto(): apaga la marca aunque la RLS no deje editar.
--  - notificaciones: tipo nuevo 'lead_retirado' (Tristán retiró un lead de
--    Joaquín del Recontacto compartido) y tipos permitidos en preferencias.
--
-- Requiere 20261006000003_recontacto_por_mes.sql.

alter table public.leads
  add column if not exists viene_de_recontacto boolean not null default false;
alter table public.leads_privados_tristan
  add column if not exists viene_de_recontacto boolean not null default false;

-- Cambiar solo la marca no es un movimiento del lead: updated_at alimenta los
-- avisos "sin novedades" y el orden de Contactado, y abrir una ficha no tiene
-- que reiniciarlos. La comparación es por jsonb para que el mismo trigger siga
-- sirviendo a las demás tablas (clientes, tareas, preferencias...), que no
-- tienen la columna.
create or replace function public.trg_leads_set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_new jsonb := to_jsonb(new);
  v_old jsonb := to_jsonb(old);
begin
  if v_new ? 'viene_de_recontacto'
     and (v_new -> 'viene_de_recontacto') is distinct from (v_old -> 'viene_de_recontacto')
     and (v_new - 'viene_de_recontacto') = (v_old - 'viene_de_recontacto') then
    return new;
  end if;
  new.updated_at = now();
  return new;
end;
$$;

-- Prende la marca cuando el lead sale de Recontacto sin cambiar de etapa
-- (vuelve a donde estaba) y la apaga al volver a Recontacto. Si sale CON
-- cambio de etapa (ej. Pedido confirmado) no se toca: ahí no "volvió".
-- sacar_de_recontacto() la prende por su cuenta cuando tiene que caer en otra
-- etapa (fallback a 'nuevo').
create or replace function public.trg_viene_de_recontacto()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.recontacto_active and not old.recontacto_active then
    new.viene_de_recontacto = false;
  elsif old.recontacto_active and not new.recontacto_active and new.etapa = old.etapa then
    new.viene_de_recontacto = true;
  end if;
  return new;
end;
$$;

revoke execute on function public.trg_viene_de_recontacto() from public, anon, authenticated;

drop trigger if exists leads_viene_de_recontacto on public.leads;
create trigger leads_viene_de_recontacto
  before update on public.leads
  for each row
  execute function public.trg_viene_de_recontacto();

drop trigger if exists leads_privados_viene_de_recontacto on public.leads_privados_tristan;
create trigger leads_privados_viene_de_recontacto
  before update on public.leads_privados_tristan
  for each row
  execute function public.trg_viene_de_recontacto();

-- Tipos de aviso permitidos: todos los vigentes (20261006000003) + el nuevo.
alter table public.notificaciones drop constraint if exists notificaciones_tipo_check;
alter table public.notificaciones add constraint notificaciones_tipo_check
  check (tipo = any (array['seguimiento_vencido','sin_movimiento','recordatorio_manual','recordatorio_automatico','lead_compartido','lead_devuelto','recontacto_mes','lead_retirado']));

-- La lista de tipos silenciables (20260914000001) había quedado atrás de
-- lead_devuelto / recontacto_mes: sin esto, silenciar esos avisos o el nuevo
-- falla al guardar las preferencias.
alter table public.preferencias_notificacion drop constraint if exists tipos_mute_valores;
alter table public.preferencias_notificacion add constraint tipos_mute_valores
  check (tipos_mute <@ array['seguimiento_vencido','sin_movimiento','recordatorio_manual','recordatorio_automatico','lead_compartido','lead_devuelto','recontacto_mes','lead_retirado']::text[]);

-- Saca un lead de Recontacto y lo deja en p_destino ('compartido' | 'privado').
-- p_desde dice en qué tabla está hoy el lead. Devuelve el id del lead en el
-- destino (cambia si cambia de espacio). Tristán puede con cualquier lead,
-- también los de Joaquín; Joaquín solo dentro del pipeline compartido.
create or replace function public.sacar_de_recontacto(p_lead_id uuid, p_desde text, p_destino text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.leads%rowtype;
  vp public.leads_privados_tristan%rowtype;
  v_es_tristan boolean := public.is_tristan();
  v_empresa text;
  v_etapa text;
  v_etapa_dest text;
  v_nuevo_id uuid;
  v_orden double precision;
  v_joaquin_email text;
  v_tristan_email text;
begin
  if p_desde not in ('compartido', 'privado') or p_destino not in ('compartido', 'privado') then
    raise exception 'Espacio inválido';
  end if;
  if not (v_es_tristan or (public.is_authorized_user() and p_desde = 'compartido' and p_destino = 'compartido')) then
    raise exception 'No tenés permiso para sacar este lead de Recontacto';
  end if;

  if p_desde = 'compartido' then
    select * into v from public.leads where id = p_lead_id for update;
    if not found then raise exception 'Lead % no encontrado', p_lead_id; end if;
    if v.trashed_at is not null then raise exception 'El lead está en la papelera'; end if;
    if not v.recontacto_active then raise exception 'El lead no está en Recontacto'; end if;
    v_empresa := v.empresa;
    v_etapa := v.etapa::text;
  else
    select * into vp from public.leads_privados_tristan where id = p_lead_id for update;
    if not found then raise exception 'Lead % no encontrado', p_lead_id; end if;
    if vp.trashed_at is not null then raise exception 'El lead está en la papelera'; end if;
    if not vp.recontacto_active then raise exception 'El lead no está en Recontacto'; end if;
    v_empresa := vp.empresa;
    v_etapa := vp.etapa::text;
  end if;

  -- Etapa previa a Recontacto = la etapa actual (Recontacto no la toca). Sin
  -- una etapa utilizable cae en 'nuevo'; 'leads_tristan' no existe en privado.
  v_etapa_dest := case
    when v_etapa is null or v_etapa = 'cerrado' then 'nuevo'
    when v_etapa = 'leads_tristan' and p_destino = 'privado' then 'nuevo'
    else v_etapa
  end;

  select email into v_joaquin_email from public.usuarios_autorizados where rol = 'joaquin' limit 1;
  select email into v_tristan_email from public.usuarios_autorizados where rol = 'tristan' limit 1;

  -- Mismo espacio: UPDATE (al fondo de la columna de destino).
  if p_desde = p_destino then
    if p_desde = 'compartido' then
      select coalesce(max(orden) + 1000, extract(epoch from now()) * 1000) into v_orden
        from public.leads where etapa = v_etapa_dest::public.etapa_enum and id <> p_lead_id;
      update public.leads
        set recontacto_active = false, recontacto_mes = null, recontacto_mes_motivo = null,
            viene_de_recontacto = true, etapa = v_etapa_dest::public.etapa_enum, orden = v_orden
        where id = p_lead_id;

      if v_es_tristan and v_joaquin_email is not null then
        insert into public.notificaciones (destinatario_email, tipo, lead_id, titulo, mensaje)
        values (
          v_joaquin_email, 'lead_retirado', p_lead_id,
          'Tristán sacó un lead de Recontacto',
          'Tristán sacó "' || v_empresa || '" de Recontacto — quedó en ' || public.etapa_label(v_etapa_dest::public.etapa_enum) || '.'
        );
      end if;
    else
      select coalesce(max(orden) + 1000, extract(epoch from now()) * 1000) into v_orden
        from public.leads_privados_tristan where etapa = v_etapa_dest::public.etapa_enum and id <> p_lead_id;
      update public.leads_privados_tristan
        set recontacto_active = false, recontacto_mes = null, recontacto_mes_motivo = null,
            viene_de_recontacto = true, etapa = v_etapa_dest::public.etapa_enum, orden = v_orden
        where id = p_lead_id;
    end if;
    return p_lead_id;
  end if;

  -- Cambio de espacio: INSERT en el destino, se mueve lo que cuelga del lead
  -- (novedades, recordatorios) y se borra el origen.
  if p_desde = 'compartido' then
    insert into public.leads_privados_tristan (
      empresa, contacto, telefono, contacto2_nombre, contacto2_telefono, rubro,
      ticket, fuente, fecha_contacto, resultado, notas, etapa, archived, cierre,
      recontacto_active, clasificacion_abc, created_by, origen_cliente_id,
      pedido_presupuestar, viene_de_recontacto
    ) values (
      v.empresa, v.contacto, v.telefono, v.contacto2_nombre, v.contacto2_telefono, v.rubro,
      v.ticket, v.fuente, v.fecha_contacto, v.resultado, v.notas, v_etapa_dest::public.etapa_enum, v.archived, v.cierre,
      false, v.clasificacion_abc, v.created_by, v.origen_cliente_id,
      v.pedido_presupuestar, true
    )
    returning id into v_nuevo_id;

    -- lead_id / lead_privado_id se cambian juntos por el check de "uno solo".
    update public.lead_novedades set lead_id = null, lead_privado_id = v_nuevo_id where lead_id = p_lead_id;
    -- Los recordatorios de Joaquín no viajan a un espacio que él no ve.
    delete from public.recordatorios
      where lead_id = p_lead_id and creado_por_email is distinct from v_tristan_email;
    update public.recordatorios set lead_id = null, lead_privado_id = v_nuevo_id where lead_id = p_lead_id;

    update public.clientes set origen_lead_id = null where origen_lead_id = p_lead_id;
    delete from public.leads where id = p_lead_id;

    -- El lead ya no existe para Joaquín: el aviso va sin lead asociado.
    if v_joaquin_email is not null then
      insert into public.notificaciones (destinatario_email, tipo, titulo, mensaje)
      values (
        v_joaquin_email, 'lead_retirado',
        'Tristán retiró un lead de Recontacto',
        'Tristán retiró "' || v_empresa || '" de Recontacto y lo pasó a su Gestión Privada.'
      );
    end if;
  else
    insert into public.leads (
      empresa, contacto, telefono, contacto2_nombre, contacto2_telefono, rubro,
      ticket, fuente, fecha_contacto, resultado, notas, etapa, archived, cierre,
      recontacto_active, clasificacion_abc, created_by, origen, origen_cliente_id,
      pedido_presupuestar, viene_de_recontacto
    ) values (
      vp.empresa, vp.contacto, vp.telefono, vp.contacto2_nombre, vp.contacto2_telefono, vp.rubro,
      vp.ticket, vp.fuente, vp.fecha_contacto, vp.resultado, vp.notas, v_etapa_dest::public.etapa_enum, vp.archived, vp.cierre,
      false, vp.clasificacion_abc, vp.created_by, 'privado_tristan', vp.origen_cliente_id,
      vp.pedido_presupuestar, true
    )
    returning id into v_nuevo_id;

    update public.lead_novedades set lead_privado_id = null, lead_id = v_nuevo_id where lead_privado_id = p_lead_id;
    update public.recordatorios set lead_privado_id = null, lead_id = v_nuevo_id where lead_privado_id = p_lead_id;

    delete from public.leads_privados_tristan where id = p_lead_id;

    if v_joaquin_email is not null then
      insert into public.notificaciones (destinatario_email, tipo, lead_id, titulo, mensaje)
      values (
        v_joaquin_email, 'lead_compartido', v_nuevo_id,
        'Tristán compartió un lead',
        'Tristán sacó "' || v_empresa || '" de Recontacto y lo pasó al pipeline compartido — quedó en '
          || public.etapa_label(v_etapa_dest::public.etapa_enum) || '.'
      );
    end if;
  end if;

  return v_nuevo_id;
end;
$$;

revoke execute on function public.sacar_de_recontacto(uuid, text, text) from public, anon;
grant execute on function public.sacar_de_recontacto(uuid, text, text) to authenticated;

-- Apaga el punto naranja de un lead. Es security definer porque Tristán no
-- puede hacer UPDATE sobre los leads de etapas de Joaquín. Solo toca la marca
-- (y el trigger de updated_at no la cuenta como movimiento).
create or replace function public.marcar_recontacto_visto(p_lead_id uuid, p_privado boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_privado then
    if not public.is_tristan() then
      raise exception 'No tenés permiso';
    end if;
    update public.leads_privados_tristan set viene_de_recontacto = false
      where id = p_lead_id and viene_de_recontacto;
  else
    if not public.is_authorized_user() then
      raise exception 'No tenés permiso';
    end if;
    update public.leads set viene_de_recontacto = false
      where id = p_lead_id and viene_de_recontacto;
  end if;
end;
$$;

revoke execute on function public.marcar_recontacto_visto(uuid, boolean) from public, anon;
grant execute on function public.marcar_recontacto_visto(uuid, boolean) to authenticated;
