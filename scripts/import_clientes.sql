-- Import de cartera de clientes existentes (~60) — NO EJECUTAR TODAVÍA.
-- Ver scripts/import_clientes.md para el formato del CSV esperado.
--
-- Uso (psql, conectado al proyecto real):
--   \i scripts/import_clientes.sql
-- o pegar el contenido en el SQL Editor del dashboard de Supabase,
-- reemplazando antes la ruta del \copy si corrés esto por psql.

begin;

create temporary table _clientes_staging (
  empresa  text,
  contacto text,
  telefono text,
  rubro    text,
  estado   text,
  notas    text
) on commit drop;

-- Ajustar la ruta al CSV final antes de correr esto.
-- \copy _clientes_staging from 'scripts/clientes_export.csv' with (format csv, header true);

insert into public.clientes (empresa, contacto, telefono, rubro, estado, notas)
select
  trim(s.empresa),
  coalesce(trim(s.contacto), ''),
  coalesce(trim(s.telefono), ''),
  nullif(trim(s.rubro), '')::public.rubro_enum,
  coalesce(nullif(trim(s.estado), ''), 'activo')::public.estado_cliente_enum,
  coalesce(trim(s.notas), '')
from _clientes_staging s
where trim(coalesce(s.empresa, '')) <> '';

-- Revisar antes de confirmar:
-- select count(*) from public.clientes;

commit;
