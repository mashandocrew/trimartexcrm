-- Trimartex CRM — "Devolver" un lead que Tristán eliminó de Leads Tristán.
--
-- Al eliminar, el lead va a la papelera en el acto (si Tristán cierra la
-- pestaña, queda ahí). Durante 40 s el front ofrece devolverlo a donde estaba:
-- Cartera o su Gestión Privada. El servidor acepta hasta 60 s (margen de red).
--
-- leads.origen / origen_cliente_id registran de dónde vino cada lead.

alter table public.leads
  add column if not exists origen text check (origen in ('cartera', 'privado_tristan')),
  add column if not exists origen_cliente_id uuid references public.clientes(id) on delete set null;

-- Backfill de los leads que Tristán ya mandó: los de Cartera llevan esa fuente;
-- el resto de sus leads en Leads Tristán vinieron (o pertenecen) a su Gestión Privada.
update public.leads l
set origen = case when l.fuente = 'Cartera de clientes' then 'cartera' else 'privado_tristan' end
from auth.users u
join public.usuarios_autorizados a on a.email = u.email and a.rol = 'tristan'
where l.created_by = u.id
  and l.etapa = 'leads_tristan'
  and l.origen is null;

update public.leads l
set origen_cliente_id = (
  select c.id from public.clientes c
  where lower(trim(c.empresa)) = lower(trim(l.empresa))
  order by c.trashed_at nulls first, c.created_at
  limit 1
)
where l.origen = 'cartera' and l.origen_cliente_id is null;

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
    clasificacion_abc, created_by, origen
  )
  select
    empresa, contacto, telefono, contacto2_nombre, contacto2_telefono, rubro,
    ticket, fuente, fecha_contacto, resultado, notas, 'leads_tristan', archived, cierre,
    recontacto_active, recontacto_stage, recontacto_next_date,
    clasificacion_abc, created_by, 'privado_tristan'
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

-- Devuelve un lead recién eliminado a su origen y lo saca del pipeline
-- compartido. Devuelve 'cartera' o 'privado_tristan'.
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
begin
  if not public.is_tristan() then
    raise exception 'Solo Tristán puede devolver leads';
  end if;

  select * into v from public.leads where id = p_lead_id for update;
  if not found then
    raise exception 'Lead % no encontrado', p_lead_id;
  end if;
  if v.created_by is distinct from auth.uid() or v.etapa <> 'leads_tristan' then
    raise exception 'Solo podés devolver leads tuyos de la columna Leads Tristán';
  end if;
  -- updated_at lo pone el trigger con el reloj del servidor; trashed_at viene
  -- del navegador y podría estar desfasado.
  if v.trashed_at is null or v.updated_at < now() - interval '60 seconds' then
    raise exception 'Se venció el tiempo para devolver este lead';
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
      clasificacion_abc, created_by
    ) values (
      v.empresa, v.contacto, v.telefono, v.contacto2_nombre, v.contacto2_telefono, v.rubro,
      v.ticket, v.fuente, v.fecha_contacto, v.resultado, v.notas, 'nuevo', v.cierre,
      v.recontacto_active, v.recontacto_stage, v.recontacto_next_date,
      v.clasificacion_abc, v.created_by
    );
  end if;

  update public.clientes set origen_lead_id = null where origen_lead_id = p_lead_id;
  delete from public.leads where id = p_lead_id;

  return v_origen;
end;
$$;

revoke execute on function public.devolver_lead_tristan(uuid) from public, anon;
grant execute on function public.devolver_lead_tristan(uuid) to authenticated;
