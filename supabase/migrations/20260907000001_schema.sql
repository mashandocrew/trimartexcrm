-- Trimartex CRM — base schema
-- Enums, allowlist, leads, lead_history, clientes.
-- "etapa" is the pipeline stage (called "column" in the original localStorage/JS model).

create extension if not exists pgcrypto;

create type public.rubro_enum as enum ('seguridad', 'limpieza', 'gastronomia', 'clubes', 'otro');

create type public.resultado_enum as enum ('sin_respuesta', 'positiva', 'negativa', 'a_confirmar');

create type public.etapa_enum as enum (
  'nuevo',
  'contactado',
  'cotizacion_pendiente',
  'cotizacion_enviada',
  'seguimiento',
  'cerrado'
);

create type public.cierre_enum as enum ('cerrado', 'no_cerrado');

create type public.estado_cliente_enum as enum ('activo', 'inactivo');

-- Allowlist: only emails present here may read/write leads data. See SETUP.md
-- for how to add/remove people; there is no UI for this on purpose.
create table public.usuarios_autorizados (
  email text primary key,
  rol text not null check (rol in ('joaquin', 'tristan')),
  created_at timestamptz not null default now()
);

create table public.leads (
  id uuid primary key default gen_random_uuid(),
  empresa text not null,
  contacto text not null default '',
  telefono text not null default '',
  rubro public.rubro_enum not null default 'otro',
  ticket numeric not null default 0,
  fuente text not null default '',
  fecha_contacto date,
  resultado public.resultado_enum not null default 'sin_respuesta',
  notas text not null default '',
  etapa public.etapa_enum not null default 'nuevo',
  archived boolean not null default false,
  cierre public.cierre_enum,
  recontacto_active boolean not null default false,
  recontacto_stage int not null default 1 check (recontacto_stage between 1 and 8),
  recontacto_next_date date,
  trashed_at timestamptz,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index leads_etapa_idx on public.leads (etapa) where trashed_at is null and archived = false;
create index leads_recontacto_idx on public.leads (recontacto_active, recontacto_stage) where trashed_at is null and archived = false;
create index leads_trashed_idx on public.leads (trashed_at) where trashed_at is not null;

create table public.lead_history (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references public.leads(id) on delete cascade,
  ts timestamptz not null default now(),
  label text not null,
  created_by uuid references auth.users(id)
);

create index lead_history_lead_id_idx on public.lead_history (lead_id, ts desc);

-- Cartera de clientes existentes de Trimartex (~60), separada del pipeline de
-- leads nuevos. origen_lead_id es opcional, para trazar qué lead se convirtió
-- en cliente cuando aplique.
create table public.clientes (
  id uuid primary key default gen_random_uuid(),
  empresa text not null,
  contacto text not null default '',
  telefono text not null default '',
  rubro public.rubro_enum,
  estado public.estado_cliente_enum not null default 'activo',
  notas text not null default '',
  origen_lead_id uuid references public.leads(id),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index clientes_estado_idx on public.clientes (estado);
