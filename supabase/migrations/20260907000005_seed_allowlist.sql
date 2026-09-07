-- Trimartex CRM — allowlist inicial.
-- Para agregar/quitar gente más adelante, ver SETUP.md (se edita a mano, sin UI).

insert into public.usuarios_autorizados (email, rol) values
  ('joaquin.23.ponce@gmail.com', 'joaquin'),
  ('tristan.gonzalez@gmail.com', 'tristan')
on conflict (email) do nothing;
