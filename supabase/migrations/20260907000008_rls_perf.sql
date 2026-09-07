-- Wrap auth.jwt() in (select ...) so Postgres evaluates it once per query
-- instead of once per row (linter: auth_rls_initplan).

create or replace function public.is_authorized_user()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.usuarios_autorizados u
    where u.email = (select auth.jwt() ->> 'email')
  );
$$;

drop policy "read own allowlist row" on public.usuarios_autorizados;

create policy "read own allowlist row"
  on public.usuarios_autorizados
  for select
  to authenticated
  using (email = (select auth.jwt() ->> 'email'));
