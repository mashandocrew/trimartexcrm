-- Trimartex CRM — reordena la columna "Contactado" del Kanban por última
-- modificación (updated_at), de más antigua a más reciente: coincide con el
-- nuevo comportamiento del frontend, donde un lead que cambia de etapa
-- siempre cae al final de la columna destino.
--
-- Misma escala que el backfill original de `orden` (epoch en segundos *
-- 1000), sólo que tomando updated_at en vez de created_at.

update public.leads
  set orden = extract(epoch from updated_at) * 1000
  where etapa = 'contactado';

update public.leads_privados_tristan
  set orden = extract(epoch from updated_at) * 1000
  where etapa = 'contactado';
