-- Trimartex CRM — lead_novedades: bitácora de novedades de contacto.
--
-- Registro append-only que un usuario adjunta manualmente a un lead para
-- dejar constancia de un contacto (qué se dijo, qué respondió), sin tocar la
-- "etapa" del pipeline. contactado_at es la fecha/hora del contacto en sí
-- (puede ser en el pasado, el usuario la elige), no necesariamente "ahora".
--
-- Es intencionalmente de solo lectura una vez creada: no hay policy de UPDATE
-- ni de DELETE (decisión de producto confirmada) — mismo patrón que
-- lead_history en 20260907000002_security.sql.

create table public.lead_novedades (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references public.leads(id) on delete cascade,
  contactado_at timestamptz not null default now(),
  mensaje text not null default '',
  respuesta text not null default '',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create index lead_novedades_lead_id_idx on public.lead_novedades (lead_id, contactado_at desc);

alter table public.lead_novedades enable row level security;

create policy "lead_novedades select if authorized"
  on public.lead_novedades for select
  to authenticated
  using (public.is_authorized_user());

create policy "lead_novedades insert if authorized"
  on public.lead_novedades for insert
  to authenticated
  with check (public.is_authorized_user());

alter publication supabase_realtime add table public.lead_novedades;

-- Fix: public.clientes fue agregada al schema (20260907000001) y el frontend
-- ya se suscribe a sus cambios de Realtime, pero nunca se agregó a la
-- publication — el sync en vivo de la pantalla Cartera estaba silenciosamente
-- roto. Corregido acá.
alter publication supabase_realtime add table public.clientes;
