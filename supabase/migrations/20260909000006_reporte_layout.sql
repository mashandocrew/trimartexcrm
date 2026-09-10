-- Trimartex CRM — Etapa 3: persistencia del layout de widgets de reportes.
--
-- Una fila por (usuario, reporte): 'leads_jp' es el reporte de desempeño de
-- Joaquín (visible para ambos roles, ya que se alimenta de datos ya
-- compartidos vía RLS); 'gestion_tristan' es el reporte comercial de
-- Tristán, exclusivo de él (decisión del gate de la Etapa 3).
--
-- `layout` guarda tanto la posición/tamaño de cada widget (lo que devuelve
-- GridStack.save()) como qué widgets están ocultos — todo en un solo JSONB
-- para no tener que migrar el esquema cada vez que se agregue un campo de
-- layout nuevo.

create table public.reporte_layout (
  email text not null references public.usuarios_autorizados(email),
  reporte text not null check (reporte in ('leads_jp', 'gestion_tristan')),
  layout jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (email, reporte)
);

create trigger reporte_layout_set_updated_at
  before update on public.reporte_layout
  for each row
  execute function public.trg_leads_set_updated_at();

alter table public.reporte_layout enable row level security;

create policy "reporte_layout select own"
  on public.reporte_layout for select
  to authenticated
  using (email = (select auth.jwt() ->> 'email'));

create policy "reporte_layout insert own"
  on public.reporte_layout for insert
  to authenticated
  with check (email = (select auth.jwt() ->> 'email'));

create policy "reporte_layout update own"
  on public.reporte_layout for update
  to authenticated
  using (email = (select auth.jwt() ->> 'email'))
  with check (email = (select auth.jwt() ->> 'email'));
