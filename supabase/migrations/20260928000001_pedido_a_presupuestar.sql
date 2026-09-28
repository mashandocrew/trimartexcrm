-- Trimartex CRM — "Pedido a presupuestar".
--
-- Al pasar un lead a "Cotización pendiente" se despliega un menú para cargar
-- qué pidió el cliente (productos, cantidades, medidas...), que es lo que hay
-- que presupuestar. Se guarda como texto libre en el propio lead, en los dos
-- pipelines (compartido y Gestión Privada de Tristán).

alter table public.leads
  add column if not exists pedido_presupuestar text not null default '';

alter table public.leads_privados_tristan
  add column if not exists pedido_presupuestar text not null default '';
