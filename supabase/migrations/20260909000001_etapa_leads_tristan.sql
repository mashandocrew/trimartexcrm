-- Trimartex CRM — nueva etapa de pipeline "leads_tristan".
--
-- Es la columna donde aterrizan los leads que Tristán decide compartir desde
-- su Gestión Privada (ver 20260909000002_leads_privados_tristan.sql). Una vez
-- en esta etapa, el lead vive en public.leads como cualquier otro y lo ven
-- ambos roles.
--
-- ALTER TYPE ... ADD VALUE no puede usarse en la misma transacción en la que
-- se referencia el valor nuevo, así que esta migración SOLO agrega el valor
-- al enum. La tabla/policies/función que lo usan van en la migración
-- siguiente.

alter type public.etapa_enum add value 'leads_tristan' before 'nuevo';
