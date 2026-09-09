-- Trimartex CRM — Etapa 4: clasificación ABC de leads.
--
-- No existía ningún campo de clasificación ABC (confirmado en el
-- reconocimiento de la Etapa 4). Se agrega como enum nullable en ambas
-- tablas de leads (compartida y Gestión Privada) para que el filtro
-- funcione igual en los dos espacios.
--
-- Decisión (no vino explícita del gate, documentada acá): carga MANUAL por
-- el usuario, no calculada automáticamente a partir del ticket — no hay
-- definición de negocio de dónde cortar A/B/C, e inventar un corte arbitrario
-- sería peor que dejarlo a criterio de quien conoce cada lead.

create type public.abc_enum as enum ('A', 'B', 'C');

alter table public.leads
  add column clasificacion_abc public.abc_enum;

alter table public.leads_privados_tristan
  add column clasificacion_abc public.abc_enum;
