-- Trimartex CRM — lead_novedades: soporte para la Gestión Privada de Tristán
-- y edición/borrado de novedades ya creadas.
--
-- Dos problemas que se arreglan acá:
--   1. lead_novedades.lead_id era NOT NULL y referenciaba solo public.leads,
--      así que en el pipeline privado no se podía registrar ninguna novedad.
--      Se agrega lead_privado_id con el mismo patrón que ya usan
--      recordatorios y notificaciones (check num_nonnulls(...) = 1).
--   2. La tabla se creó append-only a propósito (sin policy de UPDATE ni de
--      DELETE). En la práctica eso hacía imposible agregar la respuesta a una
--      novedad ya cargada, que es el flujo normal: primero se anota el
--      mensaje enviado, la respuesta llega después. Se abre UPDATE y DELETE
--      con el mismo criterio de visibilidad que recordatorios.

alter table public.lead_novedades
  alter column lead_id drop not null;

alter table public.lead_novedades
  add column if not exists lead_privado_id uuid
    references public.leads_privados_tristan(id) on delete cascade;

alter table public.lead_novedades
  drop constraint if exists lead_novedades_un_solo_lead;

alter table public.lead_novedades
  add constraint lead_novedades_un_solo_lead
  check (num_nonnulls(lead_id, lead_privado_id) = 1);

create index if not exists lead_novedades_lead_privado_id_idx
  on public.lead_novedades (lead_privado_id, contactado_at desc);

-- RLS: espeja la visibilidad del lead al que apunta la novedad, igual que
-- recordatorios. Novedad sobre un lead compartido -> cualquier usuario
-- autorizado; sobre un lead de la Gestión Privada -> solo Tristán.
drop policy if exists "lead_novedades select if authorized" on public.lead_novedades;
drop policy if exists "lead_novedades insert if authorized" on public.lead_novedades;
drop policy if exists "lead_novedades update if authorized" on public.lead_novedades;
drop policy if exists "lead_novedades delete if authorized" on public.lead_novedades;

create policy "lead_novedades select if authorized"
  on public.lead_novedades for select
  to authenticated
  using (
    (lead_id is not null and public.is_authorized_user())
    or (lead_privado_id is not null and public.is_tristan())
  );

create policy "lead_novedades insert if authorized"
  on public.lead_novedades for insert
  to authenticated
  with check (
    (lead_id is not null and public.is_authorized_user())
    or (lead_privado_id is not null and public.is_tristan())
  );

create policy "lead_novedades update if authorized"
  on public.lead_novedades for update
  to authenticated
  using (
    (lead_id is not null and public.is_authorized_user())
    or (lead_privado_id is not null and public.is_tristan())
  )
  with check (
    (lead_id is not null and public.is_authorized_user())
    or (lead_privado_id is not null and public.is_tristan())
  );

create policy "lead_novedades delete if authorized"
  on public.lead_novedades for delete
  to authenticated
  using (
    (lead_id is not null and public.is_authorized_user())
    or (lead_privado_id is not null and public.is_tristan())
  );
