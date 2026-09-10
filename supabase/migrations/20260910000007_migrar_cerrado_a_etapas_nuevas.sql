-- Trimartex CRM — segunda parte de la reestructura de etapas (ver
-- 20260910000006): ya con 'pedido_confirmado'/'entregado'/'baja'
-- disponibles en el enum, acá se los usa de verdad.

-- etapa_label() no contemplaba las etapas nuevas — sin este fix, cualquier
-- UPDATE que mueva un lead a una de ellas rompía (el trigger de auditoría
-- llama a esta función y su CASE no tiene ELSE).
create or replace function public.etapa_label(e public.etapa_enum)
returns text
language sql
immutable
set search_path = public
as $$
  select case e
    when 'leads_tristan' then 'Leads Tristán'
    when 'nuevo' then 'Nuevo'
    when 'contactado' then 'Contactado'
    when 'cotizacion_pendiente' then 'Cotización pendiente'
    when 'cotizacion_enviada' then 'Presupuesto enviado'
    when 'seguimiento' then 'Seguimiento'
    when 'cerrado' then 'Cerrado'
    when 'pedido_confirmado' then 'Pedido confirmado'
    when 'entregado' then 'Entregado'
    when 'baja' then 'Baja'
  end;
$$;

-- Los leads que hoy están en "Cerrado" se reparten según su cierre: ganado
-- (cierre = 'cerrado') pasa a "Pedido confirmado"; perdido o sin definir
-- pasa a "Baja". Confirmado con el Sr. que solo hay un caso real hoy
-- (Securitas Argentina S.A., cierre = no_cerrado -> Baja), pero la regla
-- cubre cualquier otro caso histórico o de la Gestión Privada.
update public.leads
set etapa = case when cierre = 'cerrado' then 'pedido_confirmado'::etapa_enum else 'baja'::etapa_enum end
where etapa = 'cerrado';

update public.leads_privados_tristan
set etapa = case when cierre = 'cerrado' then 'pedido_confirmado'::etapa_enum else 'baja'::etapa_enum end
where etapa = 'cerrado';

-- Backfill de preferencias_notificacion.dias_por_etapa: agrega umbrales por
-- defecto para las 3 etapas nuevas sin pisar lo que cada usuario ya tenía
-- configurado en el resto. La clave "cerrado" queda dormida (ya no matchea
-- la etapa de ningún lead) — no hace falta borrarla.
update public.preferencias_notificacion
set dias_por_etapa = dias_por_etapa || jsonb_build_object(
  'pedido_confirmado', 7, 'entregado', 30, 'baja', 30
)
where not (dias_por_etapa ? 'pedido_confirmado');
