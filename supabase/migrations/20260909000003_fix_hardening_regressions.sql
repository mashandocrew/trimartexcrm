-- Trimartex CRM — corrige dos regresiones de hardening introducidas por la
-- migración anterior (confirmadas con mcp__Supabase__get_advisors):
--
-- 1) etapa_label() se recreó con `create or replace` sin `set search_path`,
--    perdiendo el fix aplicado en 20260907000006_security_hardening.sql
--    (function_search_path_mutable).
-- 2) is_tristan() solo se revocó de "public", no de "anon" explícitamente —
--    este proyecto otorga EXECUTE a anon vía default privileges al crear la
--    función, no solo vía el pseudo-rol PUBLIC, así que anon seguía pudiendo
--    invocarla vía /rest/v1/rpc/is_tristan (mismo problema que tuvo
--    is_authorized_user antes de 20260907000006_security_hardening.sql).

create or replace function public.etapa_label(e public.etapa_enum)
returns text
language sql
immutable
set search_path = public
as $$
  select case e
    when 'leads_tristan' then 'Leads Tristán'
    when 'nuevo' then 'Nuevo'
    when 'contactado' then 'Contactado'
    when 'cotizacion_pendiente' then 'Cotización pendiente'
    when 'cotizacion_enviada' then 'Presupuesto enviado'
    when 'seguimiento' then 'Seguimiento'
    when 'cerrado' then 'Cerrado'
  end;
$$;

revoke execute on function public.is_tristan() from anon;
