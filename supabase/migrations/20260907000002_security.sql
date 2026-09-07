-- Trimartex CRM — RLS-first access control.
--
-- Google OAuth alone does not restrict who can log in: any Google account can
-- complete the OAuth handshake. The actual gate is here: every policy below
-- requires the logged-in JWT's email to exist in usuarios_autorizados. A
-- successful login with a non-allowlisted email yields a session that can
-- read/write nothing — the frontend then signs that session out and shows
-- "acceso denegado" (UX only; the real enforcement is this RLS).

create or replace function public.is_authorized_user()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.usuarios_autorizados u
    where u.email = auth.jwt() ->> 'email'
  );
$$;

create or replace function public.current_rol()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select u.rol from public.usuarios_autorizados u
  where u.email = auth.jwt() ->> 'email'
  limit 1;
$$;

alter table public.usuarios_autorizados enable row level security;
alter table public.leads enable row level security;
alter table public.lead_history enable row level security;
alter table public.clientes enable row level security;

-- usuarios_autorizados: a logged-in user may only read their own row (so the
-- frontend can check "am I allowed in?"). No insert/update/delete policy for
-- authenticated users on purpose — the allowlist is managed by hand via the
-- SQL editor / migrations, per SETUP.md, never from the app.
create policy "read own allowlist row"
  on public.usuarios_autorizados
  for select
  to authenticated
  using (email = auth.jwt() ->> 'email');

-- leads: full CRUD for both roles alike, but ONLY if authorized. No DELETE
-- policy at all — the app never hard-deletes (the "Eliminar" button sets
-- trashed_at instead); real deletes only happen from the daily pg_cron purge
-- job, which runs as postgres and bypasses RLS.
create policy "leads select if authorized"
  on public.leads for select
  to authenticated
  using (public.is_authorized_user());

create policy "leads insert if authorized"
  on public.leads for insert
  to authenticated
  with check (public.is_authorized_user());

create policy "leads update if authorized"
  on public.leads for update
  to authenticated
  using (public.is_authorized_user())
  with check (public.is_authorized_user());

-- lead_history: read-only from the app's point of view (rows are written by
-- the audit trigger in the next migration, which runs as the table owner and
-- so is unaffected by the lack of an insert policy here).
create policy "lead_history select if authorized"
  on public.lead_history for select
  to authenticated
  using (public.is_authorized_user());

-- clientes: same full-CRUD-if-authorized shape as leads. Real deletes are not
-- expected here either, but there is no papelera requirement for clientes, so
-- a delete policy is fine.
create policy "clientes select if authorized"
  on public.clientes for select
  to authenticated
  using (public.is_authorized_user());

create policy "clientes insert if authorized"
  on public.clientes for insert
  to authenticated
  with check (public.is_authorized_user());

create policy "clientes update if authorized"
  on public.clientes for update
  to authenticated
  using (public.is_authorized_user())
  with check (public.is_authorized_user());

create policy "clientes delete if authorized"
  on public.clientes for delete
  to authenticated
  using (public.is_authorized_user());
