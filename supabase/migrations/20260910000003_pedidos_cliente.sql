-- Trimartex CRM — historial de pedidos por cliente (Cartera).
--
-- Reemplaza a "ultimo_pedido_nota" (20260910000001): en vez de una única nota
-- de texto libre que se pisa cada vez que el cliente hace un pedido nuevo, se
-- guarda un registro por pedido (fecha + qué pidió), igual que "recordatorios"
-- guarda un registro por recordatorio sobre un lead. La columna
-- clientes.ultimo_pedido_nota queda sin usarse (no se dropea, siguiendo la
-- convención de este repo de dejar columnas dormidas al reemplazar una
-- feature: ver clasificacion_abc).

create table public.pedidos_cliente (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references public.clientes(id) on delete cascade,
  fecha date not null default current_date,
  descripcion text not null,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create index pedidos_cliente_cliente_idx on public.pedidos_cliente (cliente_id, fecha desc);

alter table public.pedidos_cliente enable row level security;

-- Mismas policies que "clientes": CRUD completo si el usuario está en
-- usuarios_autorizados, sin distinción de rol.
create policy "pedidos_cliente select if authorized"
  on public.pedidos_cliente for select
  to authenticated
  using (public.is_authorized_user());

create policy "pedidos_cliente insert if authorized"
  on public.pedidos_cliente for insert
  to authenticated
  with check (public.is_authorized_user());

create policy "pedidos_cliente update if authorized"
  on public.pedidos_cliente for update
  to authenticated
  using (public.is_authorized_user())
  with check (public.is_authorized_user());

create policy "pedidos_cliente delete if authorized"
  on public.pedidos_cliente for delete
  to authenticated
  using (public.is_authorized_user());

alter publication supabase_realtime add table public.pedidos_cliente;
