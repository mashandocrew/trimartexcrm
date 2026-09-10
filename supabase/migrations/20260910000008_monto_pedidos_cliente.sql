-- Trimartex CRM — agrega un monto opcional a cada pedido de la Cartera de
-- clientes, a pedido del Sr. para poder calcular nuevas estadísticas en
-- Reportes (top clientes, clientes más frecuentes, pedido más grande).
-- pedidos_cliente.descripcion (texto libre) no alcanza para esto — hace
-- falta un valor numérico. Nullable: un pedido cargado sin monto sigue
-- contando para "frecuencia" pero no para las estadísticas de $.

alter table public.pedidos_cliente
  add column monto numeric;
