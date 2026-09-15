-- Trimartex CRM — "Devolver" un lead de Leads Tristán a su origen en cualquier
-- momento (ya no solo 60 s después de eliminarlo).
--
-- Puede hacerlo Tristán (con leads suyos) o Joaquín (con cualquier lead de la
-- columna). El lead puede estar activo o en la papelera.

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
  v_es_joaquin boolean;
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
