-- Trimartex CRM — hallazgo de code review: la policy "notificaciones update
-- own" (20260909000004_notificaciones.sql) solo restringe QUÉ FILAS puede
-- tocar un usuario (las suyas), no QUÉ COLUMNAS — con el grant de UPDATE
-- default sobre toda la tabla, cualquier usuario autenticado podía pegarle
-- un PATCH directo a /rest/v1/notificaciones?id=eq.<propio> y cambiar
-- titulo, mensaje, tipo, lead_id o resetear email_enviado a false (lo que
-- dispararía un reenvío de email), no solo marcar `leida`, que es lo único
-- que la UI y el comentario original de la policy tenían pensado permitir.
--
-- Postgres RLS no puede restringir columnas por sí sola — se resuelve con un
-- grant de UPDATE acotado a la columna leida en vez del grant de tabla
-- completa.

revoke update on public.notificaciones from authenticated;
grant update (leida) on public.notificaciones to authenticated;
