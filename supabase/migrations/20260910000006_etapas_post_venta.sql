-- Trimartex CRM — reestructura las etapas finales del pipeline: reemplaza
-- "Cerrado" (con su sub-estado Cerrado/No cerrado) por tres etapas propias:
-- "Pedido confirmado", "Entregado" y "Baja". Decisión del Sr.: Pedido
-- confirmado + Entregado cuentan como negocio ganado en Reportes; Baja es
-- la nueva versión de "perdido".
--
-- ALTER TYPE ... ADD VALUE no puede usarse en la misma transacción en la
-- que se consume el valor nuevo, así que va en su propia migración —
-- la migración de datos que lo usa (mover el lead que hoy está en
-- "cerrado", actualizar etapa_label(), etc.) va aparte, después de esta.

alter type public.etapa_enum add value if not exists 'pedido_confirmado';
alter type public.etapa_enum add value if not exists 'entregado';
alter type public.etapa_enum add value if not exists 'baja';
