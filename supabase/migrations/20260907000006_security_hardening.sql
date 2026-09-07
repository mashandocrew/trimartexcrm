-- Trimartex CRM — hardening a partir de los advisors de Supabase.
--
-- 1) Fija search_path en las funciones que no lo tenían (evita que alguien con
--    privilegios para crear objetos en un schema temprano en el search_path
--    pueda "secuestrar" una función SECURITY DEFINER/plpgsql sin search_path fijo).
-- 2) current_rol() no la usa el frontend (el front lee usuarios_autorizados
--    directo) — se elimina para reducir superficie.
-- 3) purge_trashed_leads() y trg_leads_audit() no deben ser invocables por
--    anon/authenticated vía RPC (/rest/v1/rpc/...): la primera solo la llama
--    pg_cron, la segunda solo dispara como trigger.
-- 4) is_authorized_user() sigue siendo ejecutable por "authenticated" porque
--    las políticas RLS la invocan en ese contexto — pero no por "anon".

alter function public.trg_leads_set_updated_at() set search_path = public;
alter function public.trg_leads_recontacto_next_date() set search_path = public;
alter function public.etapa_label(public.etapa_enum) set search_path = public;

drop function if exists public.current_rol();

revoke execute on function public.is_authorized_user() from anon;

revoke execute on function public.purge_trashed_leads() from public, anon, authenticated;
revoke execute on function public.trg_leads_audit() from public, anon, authenticated;
