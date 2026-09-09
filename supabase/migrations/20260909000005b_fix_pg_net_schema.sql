-- Trimartex CRM — corrige el schema de pg_net.
--
-- La migración anterior (20260909000005_generar_notificaciones.sql) instaló
-- pg_net sin especificar schema, y por defecto quedó en "public" — hallazgo
-- de mcp__Supabase__get_advisors (extension_in_public). pg_net no soporta
-- `alter extension ... set schema`, así que la única forma de corregirlo es
-- recrearla. No pierde nada: se acababa de instalar, sin uso real todavía.
--
-- (Este archivo documenta un fix que ya se había aplicado directo contra la
-- base real como migración "fix_pg_net_schema" — quedaba sin su archivo
-- correspondiente en el repo.)

drop extension if exists pg_net;
create extension if not exists pg_net with schema extensions;
