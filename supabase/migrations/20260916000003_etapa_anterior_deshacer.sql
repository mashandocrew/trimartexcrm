-- Trimartex CRM — "Volver / Deshacer": devolver un lead a la etapa en la que
-- estaba antes del último movimiento, sin límite de tiempo.
--
-- NOTA sobre la fuente de datos (desvío deliberado del pedido original):
-- lead_history sirve para el pipeline compartido, pero su lead_id referencia
-- public.leads(id) y leads_privados_tristan NO tiene trigger de auditoría
-- (ver 20260909000002), así que en la Gestión Privada no hay historial que
-- consultar. Además lead_history guarda un `label` de texto ("Cambió a
-- Seguimiento"), no la etapa en sí, y 'Presupuesto enviado' rompe la
-- correspondencia 1:1 con el enum.
--
-- Por eso la etapa anterior se guarda como columna propia en ambas tablas,
-- mantenida por un trigger BEFORE UPDATE. Es la misma información, funciona
-- igual en los dos pipelines y no depende de parsear texto. lead_history
-- sigue siendo el log que se muestra en el modal; acá solo se hace el
-- backfill inicial a partir de él.

alter table public.leads
  add column if not exists etapa_anterior public.etapa_enum;

alter table public.leads_privados_tristan
  add column if not exists etapa_anterior public.etapa_enum;

create or replace function public.trg_guardar_etapa_anterior()
returns trigger
language plpgsql
as $$
begin
  if new.etapa is distinct from old.etapa then
    new.etapa_anterior = old.etapa;
  end if;
  return new;
end;
$$;

revoke execute on function public.trg_guardar_etapa_anterior() from public, anon, authenticated;

drop trigger if exists leads_guardar_etapa_anterior on public.leads;
create trigger leads_guardar_etapa_anterior
  before update on public.leads
  for each row
  execute function public.trg_guardar_etapa_anterior();

drop trigger if exists leads_privados_guardar_etapa_anterior on public.leads_privados_tristan;
create trigger leads_privados_guardar_etapa_anterior
  before update on public.leads_privados_tristan
  for each row
  execute function public.trg_guardar_etapa_anterior();

-- Backfill del pipeline compartido a partir de lead_history: para cada lead,
-- la etapa anterior es la que resultó del ANTEÚLTIMO cambio de etapa
-- registrado. Los labels se mapean de vuelta al enum (con el caso especial
-- de 'Presupuesto enviado' = cotizacion_enviada). Si el lead tiene un solo
-- cambio de etapa registrado, o ninguno, queda en null y el botón
-- "Volver" simplemente no se ofrece hasta el próximo movimiento.
create or replace function public.etapa_desde_label(p_label text)
returns public.etapa_enum
language sql
immutable
set search_path = public
as $$
  select e
  from unnest(enum_range(null::public.etapa_enum)) e
  where 'Cambió a ' || public.etapa_label(e) = p_label
     or (p_label = 'Presupuesto enviado' and e = 'cotizacion_enviada')
  limit 1;
$$;

with cambios as (
  select
    h.lead_id,
    public.etapa_desde_label(h.label) as etapa,
    row_number() over (partition by h.lead_id order by h.ts desc, h.id desc) as rn
  from public.lead_history h
  where public.etapa_desde_label(h.label) is not null
)
update public.leads l
   set etapa_anterior = c.etapa
  from cambios c
 where c.lead_id = l.id
   and c.rn = 2
   and l.etapa_anterior is null;
