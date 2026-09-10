-- Trimartex CRM — Tareas: tablero compartido tipo post-it, visible para
-- Joaquín y Tristán por igual. Mismo shape de RLS que clientes: cualquiera
-- de los dos puede crear, editar, completar o eliminar cualquier tarea, sin
-- lógica de permisos restrictiva más allá de estar autenticado.

create table public.tareas (
  id uuid primary key default gen_random_uuid(),
  titulo text not null,
  descripcion text not null default '',
  prioridad text not null default 'media' check (prioridad in ('alta','media','baja')),
  etiquetas text[] not null default '{}',
  cliente_id uuid references public.clientes(id) on delete set null,
  asignado_a text not null default 'ambos' check (asignado_a in ('joaquin','tristan','ambos')),
  completada boolean not null default false,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger tareas_set_updated_at
  before update on public.tareas
  for each row
  execute function public.trg_leads_set_updated_at();

alter table public.tareas enable row level security;

create policy "tareas select if authorized"
  on public.tareas for select
  to authenticated
  using (public.is_authorized_user());

create policy "tareas insert if authorized"
  on public.tareas for insert
  to authenticated
  with check (public.is_authorized_user());

create policy "tareas update if authorized"
  on public.tareas for update
  to authenticated
  using (public.is_authorized_user())
  with check (public.is_authorized_user());

create policy "tareas delete if authorized"
  on public.tareas for delete
  to authenticated
  using (public.is_authorized_user());

alter publication supabase_realtime add table public.tareas;
