-- Trimartex CRM — Cartera de clientes: agrega fecha de último contacto y
-- nota de último pedido, a pedido del Sr. durante pruebas en producción.
--
-- Ambos campos se cargan/editan a mano desde el modal de cliente (no hay
-- automatismo que los derive de leads/recordatorios). Sin cambios de RLS:
-- las policies existentes de "clientes" no restringen a nivel de columna.

alter table public.clientes
  add column ultimo_contacto_at date,
  add column ultimo_pedido_nota text not null default '';
