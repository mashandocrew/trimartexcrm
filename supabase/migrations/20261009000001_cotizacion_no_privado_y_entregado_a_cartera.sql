-- Trimartex CRM — dos reglas de negocio pedidas por Joaquín:
--
--  1) Desde "Cotización pendiente" en adelante un lead del pipeline compartido
--     ya no puede pasar a la Gestión Privada de Tristán: Joaquín tiene que ver
--     todo el avance. El único camino compartido -> privado que admite esas
--     etapas es sacar_de_recontacto() (devolver_lead_tristan() solo trabaja
--     con 'leads_tristan'), así que la regla vive ahí. "Baja" queda afuera: es
--     un lead perdido, no un avance.
--     Los leads que Tristán avanza dentro de su propia Gestión Privada no se
--     tocan.
--
--  2) Todo lead que llega a "Entregado" (compartido o privado) queda en
--     Cartera como Activo. Hasta ahora solo pasaba con los leads que habían
--     salido de Cartera (reactivacion_actualizar_cliente(), 20260923000003);
--     un cliente nuevo nunca entraba. trg_entregado_a_cartera() cubre los que
--     no tienen origen_cliente_id: busca el cliente por nombre de empresa (como
--     devolver_lead_tristan()) y si no existe lo crea; en ambos casos deja el
--     vínculo en origen_cliente_id, así el resto del ciclo (Baja -> Inactivo)
--     lo sigue manejando reactivacion_actualizar_cliente().
--
-- Requiere 20261008000001_recontacto_destino_y_marca.sql.

-- 1) sacar_de_recontacto: misma función que 20261008000001 + la regla de
--    etapas que ya no pueden pasar a privado.
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

  -- Desde Cotización pendiente, lo compartido se queda compartido.
  if p_desde = 'compartido' and p_destino = 'privado'
     and v_etapa in ('cotizacion_pendiente', 'cotizacion_enviada', 'seguimiento', 'pedido_confirmado', 'entregado') then
    raise exception 'Desde Cotización pendiente el lead no puede pasar a la Gestión Privada';
  end if;

  v_etapa_dest := case
    when v_etapa is null or v_etapa = 'cerrado' then 'nuevo'
    when v_etapa = 'leads_tristan' and p_destino = 'privado' then 'nuevo'
    else v_etapa
  end;

  select email into v_joaquin_email from public.usuarios_autorizados where rol = 'joaquin' limit 1;
  select email into v_tristan_email from public.usuarios_autorizados where rol = 'tristan' limit 1;

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

    update public.lead_novedades set lead_id = null, lead_privado_id = v_nuevo_id where lead_id = p_lead_id;
    delete from public.recordatorios
      where lead_id = p_lead_id and creado_por_email is distinct from v_tristan_email;
    update public.recordatorios set lead_id = null, lead_privado_id = v_nuevo_id where lead_id = p_lead_id;

    update public.clientes set origen_lead_id = null where origen_lead_id = p_lead_id;
    delete from public.leads where id = p_lead_id;

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

-- 2) Entregado -> Cartera. BEFORE para dejar el vínculo en la misma fila sin
--    un UPDATE extra (que movería updated_at y la auditoría). En el mismo
--    UPDATE, el AFTER de reactivacion_actualizar_cliente() ve el vínculo y
--    deja el cliente Activo con la fecha de último contacto.
create or replace function public.trg_entregado_a_cartera()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente uuid;
begin
  if new.etapa <> 'entregado' or new.trashed_at is not null or new.origen_cliente_id is not null then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.etapa = 'entregado' then
    return new;
  end if;

  select c.id into v_cliente from public.clientes c
  where lower(trim(c.empresa)) = lower(trim(new.empresa))
  order by c.trashed_at nulls first, c.created_at
  limit 1;

  if v_cliente is not null then
    update public.clientes
      set trashed_at = null, estado = 'activo', ultimo_contacto_at = current_date
      where id = v_cliente;
  else
    insert into public.clientes (
      empresa, contacto, telefono, contacto2_nombre, contacto2_telefono, rubro,
      notas, clasificacion_abc, created_by, estado, ultimo_contacto_at
    ) values (
      new.empresa, coalesce(new.contacto, ''), coalesce(new.telefono, ''), new.contacto2_nombre, new.contacto2_telefono, new.rubro::text,
      coalesce(new.notas, ''), new.clasificacion_abc, new.created_by, 'activo', current_date
    )
    returning id into v_cliente;
  end if;

  -- origen_lead_id apunta a leads: solo existe la fila en un UPDATE del
  -- pipeline compartido (en un INSERT todavía no está creada).
  if tg_op = 'UPDATE' and tg_table_name = 'leads' then
    update public.clientes set origen_lead_id = new.id where id = v_cliente and origen_lead_id is null;
  end if;

  new.origen_cliente_id := v_cliente;
  return new;
end;
$$;

revoke execute on function public.trg_entregado_a_cartera() from public, anon, authenticated;

create or replace trigger leads_entregado_a_cartera
  before insert or update of etapa, trashed_at on public.leads
  for each row execute function public.trg_entregado_a_cartera();

create or replace trigger leads_privados_entregado_a_cartera
  before insert or update of etapa, trashed_at on public.leads_privados_tristan
  for each row execute function public.trg_entregado_a_cartera();

-- Backfill: entregados que hoy no están en Cartera (por nombre de empresa) se
-- dan de alta como Activos. No se toca el lead (sin vínculo) para no mover su
-- updated_at.
insert into public.clientes (
  empresa, contacto, telefono, contacto2_nombre, contacto2_telefono, rubro,
  notas, clasificacion_abc, created_by, estado, ultimo_contacto_at
)
select distinct on (lower(trim(l.empresa)))
  l.empresa, coalesce(l.contacto, ''), coalesce(l.telefono, ''), l.contacto2_nombre, l.contacto2_telefono, l.rubro::text,
  coalesce(l.notas, ''), l.clasificacion_abc, l.created_by, 'activo', current_date
from (
  select empresa, contacto, telefono, contacto2_nombre, contacto2_telefono, rubro, notas,
         clasificacion_abc, created_by, etapa, trashed_at, origen_cliente_id
    from public.leads
  union all
  select empresa, contacto, telefono, contacto2_nombre, contacto2_telefono, rubro, notas,
         clasificacion_abc, created_by, etapa, trashed_at, origen_cliente_id
    from public.leads_privados_tristan
) l
where l.etapa = 'entregado' and l.trashed_at is null and l.origen_cliente_id is null
  and not exists (
    select 1 from public.clientes c where lower(trim(c.empresa)) = lower(trim(l.empresa))
  )
order by lower(trim(l.empresa));
