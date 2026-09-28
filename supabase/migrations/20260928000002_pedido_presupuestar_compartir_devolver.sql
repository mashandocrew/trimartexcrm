-- Trimartex CRM — "Pedido a presupuestar" viaja con el lead al compartir y
-- al devolver entre la Gestión Privada de Tristán y Leads Tristán.
-- Requiere 20260928000001_pedido_a_presupuestar.sql. Resto de las funciones
-- sin cambios respecto de 20260923000003 / 20260923000005.

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
begin
  if not public.is_tristan() then
    raise exception 'Solo Tristán puede compartir leads de su Gestión Privada';
  end if;

  insert into public.leads (
    empresa, contacto, telefono, contacto2_nombre, contacto2_telefono, rubro,
    ticket, fuente, fecha_contacto, resultado, notas, etapa, archived, cierre,
    recontacto_active, recontacto_stage, recontacto_next_date,
    clasificacion_abc, created_by, origen, origen_cliente_id, pedido_presupuestar
  )
  select
    empresa, contacto, telefono, contacto2_nombre, contacto2_telefono, rubro,
    ticket, fuente, fecha_contacto, resultado, notas, 'leads_tristan', archived, cierre,
    recontacto_active, recontacto_stage, recontacto_next_date,
    clasificacion_abc, created_by, 'privado_tristan', origen_cliente_id, pedido_presupuestar
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
    insert into public.notificaciones (destinatario_email, tipo, lead_id, titulo, mensaje)
    values (
      v_joaquin_email, 'lead_compartido', v_new_id,
      'Tristán compartió un lead',
      'Tristán compartió "' || v_empresa || '" con vos — ya está en la columna Leads Tristán.'
    );
  end if;

  return v_new_id;
end;
$$;

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
