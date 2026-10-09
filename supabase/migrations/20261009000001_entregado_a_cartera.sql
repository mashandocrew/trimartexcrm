-- Trimartex CRM — todo lead que llega a "Entregado" (compartido o privado)
-- queda en Cartera como Activo.
--
-- Hasta ahora solo pasaba con los leads que habían salido de Cartera
-- (reactivacion_actualizar_cliente(), 20260923000003); un cliente nuevo nunca
-- entraba. trg_entregado_a_cartera() cubre los que no tienen
-- origen_cliente_id: busca el cliente por nombre de empresa (como
-- devolver_lead_tristan()) y si no existe lo crea; en ambos casos deja el
-- vínculo en origen_cliente_id, así el resto del ciclo (Baja -> Inactivo) lo
-- sigue manejando reactivacion_actualizar_cliente().
--
-- La regla "desde Cotización pendiente no pasa a privado" está en
-- 20261009000002.

-- Entregado -> Cartera. BEFORE para dejar el vínculo en la misma fila sin
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
