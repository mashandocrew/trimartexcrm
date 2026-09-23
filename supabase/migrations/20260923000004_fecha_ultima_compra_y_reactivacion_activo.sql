-- Trimartex CRM — fecha de última compra + "Reactivación JP" pasa a Activo.
--
-- Definiciones de Tristán (segunda ronda sobre 20260923000003):
--   1) La fecha de última compra se carga a mano en el cliente (campo nuevo).
--      Si se carga un pedido con una fecha más nueva, también la actualiza.
--   2) Al mandar un cliente de Cartera a lead, el cliente pasa a Activo y en
--      Cartera queda en su propio sector "En lead" (separado de Activos e
--      Inactivos) con la etapa del lead.
--   3) Reclasificación mixta: cuando se carga/cambia la fecha de última
--      compra, el estado se calcula solo (compró este año = Activo, antes =
--      Inactivo). Si en el mismo guardado alguien eligió el estado a mano,
--      gana lo manual. Un cliente con un lead abierto no se reclasifica:
--      mientras está en Reactivación JP queda Activo.

alter table public.clientes
  add column if not exists fecha_ultima_compra date;

-- true si el cliente tiene hoy un lead abierto (no archivado, no en papelera,
-- no en Entregado/Baja) en el pipeline compartido o en la Gestión Privada.
create or replace function public.cliente_en_reactivacion(p_cliente uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.leads l
    where l.origen_cliente_id = p_cliente and l.trashed_at is null and not l.archived
      and l.etapa not in ('entregado', 'baja')
  ) or exists (
    select 1 from public.leads_privados_tristan l
    where l.origen_cliente_id = p_cliente and l.trashed_at is null and not l.archived
      and l.etapa not in ('entregado', 'baja')
  );
$$;

revoke execute on function public.cliente_en_reactivacion(uuid) from public;
revoke execute on function public.cliente_en_reactivacion(uuid) from anon;
grant execute on function public.cliente_en_reactivacion(uuid) to authenticated;

-- (3) Reclasificación al cargar la fecha de última compra.
create or replace function public.clientes_reclasificar_por_compra()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.fecha_ultima_compra is null then
    return new;
  end if;
  if tg_op = 'UPDATE' then
    if new.fecha_ultima_compra is not distinct from old.fecha_ultima_compra then
      return new;
    end if;
    if new.estado is distinct from old.estado then
      return new; -- el estado se eligió a mano en este mismo guardado
    end if;
  end if;
  if tg_op = 'UPDATE' and public.cliente_en_reactivacion(new.id) then
    return new;
  end if;

  new.estado := case
    when new.fecha_ultima_compra >= date_trunc('year', current_date)::date then 'activo'
    else 'inactivo'
  end;
  return new;
end;
$$;

drop trigger if exists clientes_reclasificar_por_compra on public.clientes;
create trigger clientes_reclasificar_por_compra
  before insert or update of fecha_ultima_compra on public.clientes
  for each row execute function public.clientes_reclasificar_por_compra();

-- (1) Un pedido nuevo con fecha más reciente actualiza la última compra (y
-- con eso dispara la reclasificación de arriba).
create or replace function public.pedidos_actualizar_ultima_compra()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.clientes
    set fecha_ultima_compra = new.fecha
    where id = new.cliente_id
      and (fecha_ultima_compra is null or fecha_ultima_compra < new.fecha);
  return new;
end;
$$;

revoke execute on function public.pedidos_actualizar_ultima_compra() from public;
revoke execute on function public.pedidos_actualizar_ultima_compra() from anon;
revoke execute on function public.pedidos_actualizar_ultima_compra() from authenticated;

drop trigger if exists pedidos_actualizar_ultima_compra on public.pedidos_cliente;
create trigger pedidos_actualizar_ultima_compra
  after insert or update of fecha on public.pedidos_cliente
  for each row execute function public.pedidos_actualizar_ultima_compra();

-- (2) Mandar a lead = el cliente pasa a Activo.
create or replace function public.reactivacion_cliente_a_activo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.origen_cliente_id is not null and new.trashed_at is null
     and new.etapa not in ('entregado', 'baja') then
    update public.clientes set estado = 'activo'
      where id = new.origen_cliente_id and estado <> 'activo';
  end if;
  return new;
end;
$$;

revoke execute on function public.reactivacion_cliente_a_activo() from public;
revoke execute on function public.reactivacion_cliente_a_activo() from anon;
revoke execute on function public.reactivacion_cliente_a_activo() from authenticated;

drop trigger if exists leads_reactivacion_activo on public.leads;
create trigger leads_reactivacion_activo
  after insert on public.leads
  for each row execute function public.reactivacion_cliente_a_activo();

drop trigger if exists leads_privados_reactivacion_activo on public.leads_privados_tristan;
create trigger leads_privados_reactivacion_activo
  after insert on public.leads_privados_tristan
  for each row execute function public.reactivacion_cliente_a_activo();

-- Backfill: los clientes que ya están como lead pasan a Activo.
update public.clientes c
  set estado = 'activo'
  where c.trashed_at is null and c.estado <> 'activo'
    and public.cliente_en_reactivacion(c.id);

-- Cierre del ciclo (de 20260923000003) + un caso más: si el lead vuelve de
-- la papelera, el cliente vuelve a quedar Activo en Reactivación JP.
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
  elsif new.trashed_at is null and old.trashed_at is not null
     and new.etapa not in ('entregado', 'baja') then
    update public.clientes set estado = 'activo'
      where id = new.origen_cliente_id;
  end if;

  return new;
end;
$$;
