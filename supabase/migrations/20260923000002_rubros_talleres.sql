-- Trimartex CRM — agrega los rubros de talleres a rubro_enum (ver
-- trimartex-crm.html, const RUBROS): Taller mecánico, Taller metalúrgico,
-- Taller de pintura y Taller de carpintería.
--
-- Las claves son la etiqueta sin tildes ni espacios, para que
-- mapRubroACliente() matchee exacto un rubro de Cartera escrito igual.
--
-- Aditivo, no destructivo: agrega valores al enum, no toca filas existentes.
alter type public.rubro_enum add value if not exists 'tallermecanico';
alter type public.rubro_enum add value if not exists 'tallermetalurgico';
alter type public.rubro_enum add value if not exists 'tallerdepintura';
alter type public.rubro_enum add value if not exists 'tallerdecarpinteria';
