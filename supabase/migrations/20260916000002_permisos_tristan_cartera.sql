-- Trimartex CRM — permisos de Tristán sobre la cartera compartida (leads).
--
-- Regla de negocio confirmada por el cliente:
--   * Etapas "nuevo" y "contactado": zona de Joaquín. Tristán las ve, pero
--     NO puede mover, editar, eliminar ni archivar leads que estén ahí.
--   * "leads_tristan" y de "cotizacion_pendiente" en adelante: zona de
--     escritura de Tristán — control total (mover a cualquier etapa, editar,
--     soft-delete vía trashed_at, archivar, y deshacer todo eso sin límite
--     de tiempo).
--
-- Se implementa en RLS además del frontend: el bloqueo no depende de que la
-- UI esconda un botón. El conjunto de etapas de solo lectura vive en una
-- sola función (puede_editar_lead_tristan) para no repetir el array en cada
-- policy; ajustar la regla es cambiar esa función y nada más.

-- Equivalente de is_tristan() para el otro rol. No se usa todavía en ninguna
-- policy, pero faltaba para poder escribir reglas simétricas.
create or replace function public.is_joaquin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.usuarios_autorizados u
    where u.email = (select auth.jwt() ->> 'email')
      and u.rol = 'joaquin'
  );
$$;

revoke execute on function public.is_joaquin() from public;
revoke execute on function public.is_joaquin() from anon;
grant execute on function public.is_joaquin() to authenticated;

-- true si una fila de `leads` en esa etapa cae en la zona de escritura de
-- Tristán. Si mañana "leads_tristan" pasa a ser solo lectura para él,
-- alcanza con agregarla al array de acá.
create or replace function public.puede_editar_lead_tristan(etapa_actual public.etapa_enum)
returns boolean
language sql
immutable
set search_path = public
as $$
  select etapa_actual is null
     or etapa_actual <> all (array['nuevo', 'contactado']::public.etapa_enum[]);
$$;

revoke execute on function public.puede_editar_lead_tristan(public.etapa_enum) from public;
revoke execute on function public.puede_editar_lead_tristan(public.etapa_enum) from anon;
grant execute on function public.puede_editar_lead_tristan(public.etapa_enum) to authenticated;

-- UPDATE: se evalúa la etapa ANTES (using) y DESPUÉS (with check) del cambio.
-- Así Tristán no puede ni sacar un lead de la zona de Joaquín ni meter uno
-- suyo adentro; Joaquín sigue sin restricción alguna.
drop policy if exists "leads update if authorized" on public.leads;

create policy "leads update if authorized"
  on public.leads for update
  to authenticated
  using (
    public.is_authorized_user()
    and (not public.is_tristan() or public.puede_editar_lead_tristan(etapa))
  )
  with check (
    public.is_authorized_user()
    and (not public.is_tristan() or public.puede_editar_lead_tristan(etapa))
  );

-- Mismo criterio al crear: Tristán no puede dar de alta un lead directamente
-- en "nuevo" ni en "contactado". (compartir_lead_tristan() y
-- devolver_lead_tristan() son security definer, así que no se ven afectadas.)
drop policy if exists "leads insert if authorized" on public.leads;

create policy "leads insert if authorized"
  on public.leads for insert
  to authenticated
  with check (
    public.is_authorized_user()
    and (not public.is_tristan() or public.puede_editar_lead_tristan(etapa))
  );
