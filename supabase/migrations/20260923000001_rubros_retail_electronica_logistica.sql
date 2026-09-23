-- Trimartex CRM — agrega los rubros Retail, Electrónica y Logística a
-- rubro_enum (ver trimartex-crm.html, const RUBROS).
--
-- El rubro Cannabis ('canabis') se quitó del desplegable del frontend.
-- Postgres no permite borrar un valor de un enum sin recrear el tipo, así que
-- el valor queda en la base (ningún lead lo usa) pero ya no se ofrece.
--
-- Aditivo, no destructivo: agrega valores al enum, no toca filas existentes.
alter type public.rubro_enum add value if not exists 'retail';
alter type public.rubro_enum add value if not exists 'electronica';
alter type public.rubro_enum add value if not exists 'logistica';
