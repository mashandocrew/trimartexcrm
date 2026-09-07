-- Trimartex CRM — papelera con expiración automática + Realtime.
--
-- "Eliminar" en el front nunca hace DELETE real: solo pone trashed_at = now().
-- Este job corre una vez al día y borra en serio lo que lleva > 7 días en la
-- papelera. Corre como el rol que ejecuta pg_cron (bypassa RLS), así que no
-- necesita ninguna policy de DELETE para el rol authenticated.

create extension if not exists pg_cron with schema extensions;

create or replace function public.purge_trashed_leads()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.leads
  where trashed_at is not null
    and trashed_at < now() - interval '7 days';
$$;

select cron.schedule(
  'trimartex-purge-trash',
  '0 6 * * *', -- 03:00 America/Argentina (UTC-3), todos los días
  $$select public.purge_trashed_leads();$$
);

-- Realtime: para que un cambio de Joaquín se refleje en vivo en la sesión de
-- Tristán (y viceversa) sin recargar.
alter publication supabase_realtime add table public.leads;
alter publication supabase_realtime add table public.lead_history;
