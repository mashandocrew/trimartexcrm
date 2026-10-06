-- Trimartex CRM — nueva etapa "En conversación", entre "Contactado" y
-- "Cotización pendiente": prospectos que ya respondieron y son potables,
-- pero todavía no pidieron cotización.
--
-- ALTER TYPE ... ADD VALUE no puede usarse en la misma transacción en la
-- que se consume el valor nuevo, así que va sola; el resto (etapa_label(),
-- permisos, umbrales de alertas) está en 20261006000002.

alter type public.etapa_enum add value if not exists 'en_conversacion' after 'contactado';
