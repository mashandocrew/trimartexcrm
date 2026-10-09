-- Trimartex CRM — un lead del pipeline compartido que llegó a "Cotización
-- pendiente" ya no puede pasar a la Gestión Privada de Tristán: Joaquín tiene
-- que ver todo el avance.
--
-- No alcanza con mirar la etapa actual: desde Cotización pendiente Tristán
-- puede mover el lead a "Leads Tristán" (es su zona) y devolverlo, o pasarlo a
-- Baja, mandarlo a Recontacto y sacarlo hacia privado. Por eso la regla es una
-- marca permanente, leads.paso_por_cotizacion: se prende al llegar a
-- Cotización pendiente o cualquier etapa posterior (Baja no cuenta: no es un
-- avance) y nunca se apaga, ni siquiera si el cliente la manda en false.
--
-- La respetan los dos únicos caminos compartido -> privado:
--   * sacar_de_recontacto() (20261008000001).
--   * devolver_lead_tristan() — también el "deshacer" de 40 s post-eliminación,
--     que usa la misma RPC. Joaquín sigue sin restricciones.
-- Los leads que Tristán avanza dentro de su propia Gestión Privada no se tocan.
--
-- Requiere 20261009000001.

-- 1) Marca permanente.
alter table public.leads
  add column if not exists paso_por_cotizacion boolean not null default false;

create or replace function public.trg_paso_por_cotizacion()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and old.paso_por_cotizacion then
    new.paso_por_cotizacion := true;
  end if;
  if new.etapa in ('cotizacion_pendiente', 'cotizacion_enviada', 'seguimiento', 'pedido_confirmado', 'entregado') then
    new.paso_por_cotizacion := true;
  end if;
  return new;
end;
$$;

revoke execute on function public.trg_paso_por_cotizacion() from public, anon, authenticated;

create or replace trigger leads_paso_por_cotizacion
  before insert or update on public.leads
  for each row execute function public.trg_paso_por_cotizacion();

-- 2) Las marcas internas (viene_de_recontacto, paso_por_cotizacion) no son un
--    movimiento del lead: un cambio que toca solo eso no pisa updated_at.
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
     and v_new is distinct from v_old
     and (v_new - 'viene_de_recontacto' - 'paso_por_cotizacion') = (v_old - 'viene_de_recontacto' - 'paso_por_cotizacion') then
    return new;
  end if;
  new.updated_at = now();
  return new;
end;
$$;

-- 3) Backfill: la etapa actual o cualquier paso previo registrado en el
--    historial.
update public.leads l
  set paso_por_cotizacion = true
  where not l.paso_por_cotizacion
    and (
      l.etapa in ('cotizacion_pendiente', 'cotizacion_enviada', 'seguimiento', 'pedido_confirmado', 'entregado')
      or exists (
        select 1 from public.lead_history h
        where h.lead_id = l.id
          and public.etapa_desde_label(h.label) in ('cotizacion_pendiente', 'cotizacion_enviada', 'seguimiento', 'pedido_confirmado', 'entregado')
      )
    );

-- 4) sacar_de_recontacto: misma función que 20261008000001 + el bloqueo.
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

  -- Un lead compartido que pasó por Cotización pendiente se queda compartido.
  if p_desde = 'compartido' and p_destino = 'privado' and v.paso_por_cotizacion then
    raise exception 'Este lead ya pasó por Cotización pendiente: no puede pasar a la Gestión Privada';
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

-- 5) devolver_lead_tristan: misma función que 20260928000002 + el bloqueo.
create or replace function public.devolver_lead_tristan(p_lead_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.leads%rowtype;
  v_origen text;
  v_cliente uuid;
  v_privado_id uuid;
  v_es_joaquin boolean;
  v_tristan_email text;
begin
  select exists (
    select 1 from public.usuarios_autorizados u
    where u.email = (select auth.jwt() ->> 'email') and u.rol = 'joaquin'
  ) into v_es_joaquin;

  if not (public.is_tristan() or v_es_joaquin) then
    raise exception 'No tenés permiso para devolver leads';
  end if;

  select * into v from public.leads where id = p_lead_id for update;
  if not found then
    raise exception 'Lead % no encontrado', p_lead_id;
  end if;
  if v.etapa <> 'leads_tristan' then
    raise exception 'Solo se pueden devolver leads de la columna Leads Tristán';
  end if;
  if not v_es_joaquin and v.created_by is distinct from auth.uid() then
    raise exception 'Solo podés devolver leads tuyos';
  end if;
  if not v_es_joaquin and v.paso_por_cotizacion then
    raise exception 'Este lead ya pasó por Cotización pendiente: no se puede devolver';
  end if;

  v_origen := coalesce(v.origen, case when v.fuente = 'Cartera de clientes' then 'cartera' else 'privado_tristan' end);

  if v_origen = 'cartera' then
    v_cliente := v.origen_cliente_id;
    if v_cliente is null then
      select c.id into v_cliente from public.clientes c
      where lower(trim(c.empresa)) = lower(trim(v.empresa))
      order by c.trashed_at nulls first, c.created_at
      limit 1;
    end if;

    if v_cliente is not null then
      update public.clientes set trashed_at = null, estado = 'inactivo' where id = v_cliente;
    else
      insert into public.clientes (
        empresa, contacto, telefono, contacto2_nombre, contacto2_telefono,
        notas, clasificacion_abc, created_by
      ) values (
        v.empresa, v.contacto, v.telefono, v.contacto2_nombre, v.contacto2_telefono,
        v.notas, v.clasificacion_abc, v.created_by
      );
    end if;
  else
    insert into public.leads_privados_tristan (
      empresa, contacto, telefono, contacto2_nombre, contacto2_telefono, rubro,
      ticket, fuente, fecha_contacto, resultado, notas, etapa, cierre,
      recontacto_active, recontacto_stage, recontacto_next_date,
      clasificacion_abc, created_by, origen_cliente_id, pedido_presupuestar
    ) values (
      v.empresa, v.contacto, v.telefono, v.contacto2_nombre, v.contacto2_telefono, v.rubro,
      v.ticket, v.fuente, v.fecha_contacto, v.resultado, v.notas, 'nuevo', v.cierre,
      v.recontacto_active, v.recontacto_stage, v.recontacto_next_date,
      v.clasificacion_abc, v.created_by, v.origen_cliente_id, v.pedido_presupuestar
    )
    returning id into v_privado_id;
  end if;

  update public.clientes set origen_lead_id = null where origen_lead_id = p_lead_id;
  delete from public.leads where id = p_lead_id;

  if v_es_joaquin then
    select email into v_tristan_email from public.usuarios_autorizados where rol = 'tristan' limit 1;
    if v_tristan_email is not null then
      insert into public.notificaciones (destinatario_email, tipo, lead_privado_id, titulo, mensaje)
      values (
        v_tristan_email, 'lead_devuelto', v_privado_id,
        'Joaquín te devolvió un lead',
        'Joaquín sacó "' || v.empresa || '" de Leads Tristán y lo devolvió a '
          || case when v_origen = 'cartera' then 'Cartera.' else 'tu Gestión Privada (columna Nuevo).' end
      );
    end if;
  end if;

  return v_origen;
end;
$$;

revoke execute on function public.devolver_lead_tristan(uuid) from public, anon;
grant execute on function public.devolver_lead_tristan(uuid) to authenticated;
