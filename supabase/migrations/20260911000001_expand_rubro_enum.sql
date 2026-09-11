-- Trimartex CRM — amplía rubro_enum a los 36 rubros que ahora ofrece el
-- desplegable de "Nuevo lead" (ver trimartex-crm.html, const RUBROS).
--
-- rubro_enum tenía solo los 5 valores originales (seguridad, limpieza,
-- gastronomia, clubes, otro). El frontend se amplió para ofrecer cada rubro
-- real ya cargado en la Cartera de clientes, pero el enum de la base nunca se
-- actualizó — cualquier insert/update de un lead con uno de los rubros nuevos
-- (Construcción, Café, etc.) fallaba en la base sin importar la etapa,
-- rompiendo silenciosamente la creación y edición de leads.
--
-- Aditivo, no destructivo: agrega valores al enum, no toca filas existentes.
alter type public.rubro_enum add value if not exists 'construccion';
alter type public.rubro_enum add value if not exists 'cafe';
alter type public.rubro_enum add value if not exists 'restaurante';
alter type public.rubro_enum add value if not exists 'gimnasios';
alter type public.rubro_enum add value if not exists 'alimentos';
alter type public.rubro_enum add value if not exists 'electricidad';
alter type public.rubro_enum add value if not exists 'aberturas';
alter type public.rubro_enum add value if not exists 'transporte';
alter type public.rubro_enum add value if not exists 'marcademoda';
alter type public.rubro_enum add value if not exists 'bebidas';
alter type public.rubro_enum add value if not exists 'lubricentro';
alter type public.rubro_enum add value if not exists 'bodega';
alter type public.rubro_enum add value if not exists 'fertilizantes';
alter type public.rubro_enum add value if not exists 'tecnologia';
alter type public.rubro_enum add value if not exists 'cerveceria';
alter type public.rubro_enum add value if not exists 'matafuegos';
alter type public.rubro_enum add value if not exists 'club';
alter type public.rubro_enum add value if not exists 'gruas';
alter type public.rubro_enum add value if not exists 'mineria';
alter type public.rubro_enum add value if not exists 'mallaantigranizo';
alter type public.rubro_enum add value if not exists 'insumosmedicos';
alter type public.rubro_enum add value if not exists 'filtrados';
alter type public.rubro_enum add value if not exists 'cal';
alter type public.rubro_enum add value if not exists 'bar';
alter type public.rubro_enum add value if not exists 'casafunebre';
alter type public.rubro_enum add value if not exists 'etiquetas';
alter type public.rubro_enum add value if not exists 'desinfecciones';
alter type public.rubro_enum add value if not exists 'inmobiliaria';
alter type public.rubro_enum add value if not exists 'canabis';
alter type public.rubro_enum add value if not exists 'carpas';
alter type public.rubro_enum add value if not exists 'calefaccion';
