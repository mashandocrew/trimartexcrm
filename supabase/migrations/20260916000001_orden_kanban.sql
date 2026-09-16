-- Trimartex CRM — orden vertical de las cards dentro de una misma columna
-- del Kanban (estilo Trello).
--
-- `orden` es un double precision con "fractional indexing": al soltar una
-- card entre otras dos se le asigna el punto medio entre los `orden` de sus
-- vecinas, así reordenar nunca requiere reescribir el resto de la columna.
-- Si no hay vecina de un lado se suma/resta un step fijo (ORDEN_STEP = 1000
-- en el frontend).
--
-- Escala elegida: epoch en segundos * 1000. De esa forma el default de una
-- fila nueva (now()) la deja siempre al fondo de su columna y coincide con
-- el backfill hecho a partir de created_at — un solo criterio, sin mezclar
-- escalas.

alter table public.leads
  add column if not exists orden double precision;

alter table public.leads_privados_tristan
  add column if not exists orden double precision;

update public.leads
  set orden = extract(epoch from created_at) * 1000
  where orden is null;

update public.leads_privados_tristan
  set orden = extract(epoch from created_at) * 1000
  where orden is null;

alter table public.leads
  alter column orden set default (extract(epoch from now()) * 1000),
  alter column orden set not null;

alter table public.leads_privados_tristan
  alter column orden set default (extract(epoch from now()) * 1000),
  alter column orden set not null;

create index if not exists leads_etapa_orden_idx
  on public.leads (etapa, orden);

create index if not exists leads_privados_tristan_etapa_orden_idx
  on public.leads_privados_tristan (etapa, orden);
