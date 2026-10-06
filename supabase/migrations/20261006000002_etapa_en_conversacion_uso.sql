-- Trimartex CRM — segunda parte de la etapa "En conversación" (ver
-- 20261006000001): ya con el valor disponible en el enum, acá se lo usa.

-- etapa_label(): sin este caso, mover un lead a "En conversación" rompía el
-- trigger de auditoría (el CASE no tiene ELSE).
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
    when 'en_conversacion' then 'En conversación'
    when 'cotizacion_pendiente' then 'Cotización pendiente'
    when 'cotizacion_enviada' then 'Presupuesto enviado'
    when 'seguimiento' then 'Seguimiento'
    when 'cerrado' then 'Cerrado'
    when 'pedido_confirmado' then 'Pedido confirmado'
    when 'entregado' then 'Entregado'
    when 'baja' then 'Baja'
  end;
$$;

-- "En conversación" queda en la zona de Joaquín, igual que "Nuevo" y
-- "Contactado": Tristán la ve (en su pestaña Contactado/Recontacto) en solo
-- lectura. Las policies de leads ya usan esta función, no hace falta tocarlas.
create or replace function public.puede_editar_lead_tristan(etapa_actual public.etapa_enum)
returns boolean
language sql
immutable
set search_path = public
as $$
  select etapa_actual is null
     or etapa_actual <> all (array['nuevo', 'contactado', 'en_conversacion']::public.etapa_enum[]);
$$;

-- Umbral de la alerta "sin movimiento" para la etapa nueva: sin la clave,
-- generar_notificaciones() simplemente no alerta en esa etapa. Se arranca
-- con el mismo valor que cada usuario tenga en "Contactado".
update public.preferencias_notificacion
set dias_por_etapa = dias_por_etapa || jsonb_build_object(
  'en_conversacion', coalesce((dias_por_etapa ->> 'contactado')::int, 3)
)
where not (dias_por_etapa ? 'en_conversacion');
