-- Trimartex CRM — etiquetas ABC también en Cartera de clientes, a pedido del
-- Sr.: reincorpora la clasificación ABC (que se había sacado del todo de la
-- UI en la Etapa de hardening posterior al lanzamiento) ampliada a Cartera y
-- reasignable desde la tarjeta de cualquier etapa/pipeline, no solo desde el
-- modal. leads y leads_privados_tristan ya tienen la columna
-- clasificacion_abc (abc_enum: 'A'|'B'|'C', nullable) dormida desde entonces
-- — acá solo se suma a clientes con el mismo tipo, para que las tres tablas
-- usen la misma clasificación.

alter table public.clientes
  add column clasificacion_abc abc_enum;
