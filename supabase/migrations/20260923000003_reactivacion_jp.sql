-- Trimartex CRM — "Reactivación JP": clientes de Cartera que están como lead.
--
-- Pedido de Tristán: cuando un cliente de Cartera se manda al pipeline, NO se
-- saca de Cartera (se elimina la opción "Eliminar de cartera" del asistente).
-- El cliente sigue mostrándose igual que siempre y además lleva una etiqueta
-- "Reactivación JP · <etapa>" con la etapa en vivo de su lead. La etiqueta se
-- deriva en el front de leads.origen_cliente_id — no hay columna nueva en
-- clientes que mantener sincronizada.
--
-- Lo que sí vive acá, en el servidor, es el cierre del ciclo:
--   * El lead llega a "entregado"  -> el cliente pasa a Activo.
--   * El lead llega a "baja" o se manda a la papelera -> el cliente pasa a
--     Inactivo y su "último contacto" queda con la fecha de ese día.
-- Es un trigger (no lógica del front) para que funcione igual lo mueva
-- Joaquín, Tristán o cualquier otra sesión.

-- 1) Gestión Privada también recuerda de qué cliente vino, así el vínculo no
--    se pierde cuando Tristán comparte el lead a Leads Tristán.
alter table public.leads_privados_tristan
  add column if not exists origen_cliente_id uuid references public.clientes(id) on delete set null;

create index if not exists leads_origen_cliente_idx
  on public.leads (origen_cliente_id) where origen_cliente_id is not null;
create index if not exists leads_privados_origen_cliente_idx
  on public.leads_privados_tristan (origen_cliente_id) where origen_cliente_id is not null;

-- 2) Backfill: leads que ya salieron de Cartera antes de este cambio y
--    quedaron sin vínculo. Solo se vincula si el nombre de la empresa matchea
--    exactamente UN cliente — ante la duda, mejor sin etiqueta que con la
--    etiqueta en el cliente equivocado.
update public.leads l
set origen_cliente_id = m.cliente_id
from (
  select l2.id as lead_id, min(c.id::text)::uuid as cliente_id
  from public.leads l2
  join public.clientes c on lower(trim(c.empresa)) = lower(trim(l2.empresa)) and c.trashed_at is null
  where l2.origen_cliente_id is null and l2.fuente = 'Cartera de clientes'
  group by l2.id
  having count(*) = 1
) m
where l.id = m.lead_id;

update public.leads_privados_tristan l
set origen_cliente_id = m.cliente_id
from (
  select l2.id as lead_id, min(c.id::text)::uuid as cliente_id
  from public.leads_privados_tristan l2
  join public.clientes c on lower(trim(c.empresa)) = lower(trim(l2.empresa)) and c.trashed_at is null
  where l2.origen_cliente_id is null and l2.fuente = 'Cartera de clientes'
  group by l2.id
  having count(*) = 1
) m
where l.id = m.lead_id;

-- 3) Trigger que actualiza el estado del cliente según cómo termina el lead.
--    Solo actúa en la transición (cuando la etapa cambia a entregado/baja o
--    trashed_at pasa de null a una fecha), no en cada update del lead.
--    Borrados físicos (devolver_lead_tristan, purga de la papelera) no tocan
--    el estado: "devolver" no es un resultado de venta, y la purga llega
--    después de que el paso a la papelera ya lo marcó Inactivo.
create or replace function public.reactivacion_actualizar_cliente()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.origen_cliente_id is null then
    return new;
  end if;

  if new.etapa = 'entregado' and old.etapa is distinct from 'entregado' and new.trashed_at is null then
    update public.clientes
      set estado = 'activo', ultimo_contacto_at = current_date
      where id = new.origen_cliente_id;
  elsif (new.etapa = 'baja' and old.etapa is distinct from 'baja' and new.trashed_at is null)
     or (new.trashed_at is not null and old.trashed_at is null) then
    update public.clientes
      set estado = 'inactivo', ultimo_contacto_at = current_date
      where id = new.origen_cliente_id;
  end if;

  return new;
end;
$$;

revoke execute on function public.reactivacion_actualizar_cliente() from public;
revoke execute on function public.reactivacion_actualizar_cliente() from anon;
revoke execute on function public.reactivacion_actualizar_cliente() from authenticated;

drop trigger if exists leads_reactivacion_cliente on public.leads;
create trigger leads_reactivacion_cliente
  after update of etapa, trashed_at on public.leads
  for each row execute function public.reactivacion_actualizar_cliente();

drop trigger if exists leads_privados_reactivacion_cliente on public.leads_privados_tristan;
create trigger leads_privados_reactivacion_cliente
  after update of etapa, trashed_at on public.leads_privados_tristan
  for each row execute function public.reactivacion_actualizar_cliente();

-- 4) compartir_lead_tristan: lleva el vínculo con el cliente de Gestión
--    Privada a Leads Tristán. Resto sin cambios.
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
    clasificacion_abc, created_by, origen, origen_cliente_id
  )
  select
    empresa, contacto, telefono, contacto2_nombre, contacto2_telefono, rubro,
    ticket, fuente, fecha_contacto, resultado, notas, 'leads_tristan', archived, cierre,
    recontacto_active, recontacto_stage, recontacto_next_date,
    clasificacion_abc, created_by, 'privado_tristan', origen_cliente_id
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

-- 5) devolver_lead_tristan: al volver a Gestión Privada, conserva el vínculo
--    con el cliente. Resto sin cambios respecto de 20260915000002.
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
      update public.clientes set trashed_at = null where id = v_cliente;
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
      clasificacion_abc, created_by, origen_cliente_id
    ) values (
      v.empresa, v.contacto, v.telefono, v.contacto2_nombre, v.contacto2_telefono, v.rubro,
      v.ticket, v.fuente, v.fecha_contacto, v.resultado, v.notas, 'nuevo', v.cierre,
      v.recontacto_active, v.recontacto_stage, v.recontacto_next_date,
      v.clasificacion_abc, v.created_by, v.origen_cliente_id
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
