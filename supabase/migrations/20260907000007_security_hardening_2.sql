-- El grant EXECUTE por defecto de Postgres es a PUBLIC (no a "anon"
-- puntualmente), así que revocar solo de "anon" no alcanza: hay que revocar
-- de PUBLIC y volver a otorgar explícitamente solo a "authenticated", que es
-- quien lo necesita para que las políticas RLS puedan invocarla.
revoke execute on function public.is_authorized_user() from public;
grant execute on function public.is_authorized_user() to authenticated;
