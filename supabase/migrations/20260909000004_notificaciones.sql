-- Trimartex CRM — Etapa 2: notificaciones in-app + email.
--
-- Tres tablas nuevas:
--   preferencias_notificacion: config por usuario (canales, umbral de días).
--   notificaciones: bandeja in-app; email_enviado la marca el edge function
--     send-notification-email una vez que Resend confirma el envío.
--   recordatorios: recordatorios manuales (creados a mano sobre un lead) y
--     automáticos, que generar_notificaciones() convierte en notificaciones
--     cuando llega fecha_disparo.
--
-- Cada notificación/recordatorio referencia como máximo uno de
-- lead_id (leads) o lead_privado_id (leads_privados_tristan) — nunca ambos —
-- para poder apuntar tanto al pipeline compartido como a la Gestión Privada
-- de Tristán sin mezclar los dos esquemas de RLS.

create table public.preferencias_notificacion (
  email text primary key references public.usuarios_autorizados(email),
  canal_inapp boolean not null default true,
  canal_email boolean not null default true,
  dias_sin_seguimiento int not null default 3 check (dias_sin_seguimiento between 1 and 30),
  updated_at timestamptz not null default now()
);

create trigger preferencias_notificacion_set_updated_at
  before update on public.preferencias_notificacion
  for each row
  execute function public.trg_leads_set_updated_at();

insert into public.preferencias_notificacion (email)
select email from public.usuarios_autorizados
on conflict (email) do nothing;

alter table public.preferencias_notificacion enable row level security;

create policy "preferencias select own"
  on public.preferencias_notificacion for select
  to authenticated
  using (email = (select auth.jwt() ->> 'email'));

create policy "preferencias insert own"
  on public.preferencias_notificacion for insert
  to authenticated
  with check (email = (select auth.jwt() ->> 'email'));

create policy "preferencias update own"
  on public.preferencias_notificacion for update
  to authenticated
  using (email = (select auth.jwt() ->> 'email'))
  with check (email = (select auth.jwt() ->> 'email'));

create table public.notificaciones (
  id uuid primary key default gen_random_uuid(),
  destinatario_email text not null references public.usuarios_autorizados(email),
  tipo text not null check (tipo in ('seguimiento_vencido','sin_movimiento','recordatorio_manual','recordatorio_automatico','lead_compartido')),
  lead_id uuid references public.leads(id) on delete cascade,
  lead_privado_id uuid references public.leads_privados_tristan(id) on delete cascade,
  titulo text not null,
  mensaje text not null default '',
  leida boolean not null default false,
  email_enviado boolean not null default false,
  created_at timestamptz not null default now(),
  check (num_nonnulls(lead_id, lead_privado_id) <= 1)
);

create index notificaciones_destinatario_idx on public.notificaciones (destinatario_email, leida, created_at desc);
create index notificaciones_pendientes_email_idx on public.notificaciones (email_enviado) where not email_enviado;

alter table public.notificaciones enable row level security;

create policy "notificaciones select own"
  on public.notificaciones for select
  to authenticated
  using (destinatario_email = (select auth.jwt() ->> 'email'));

-- Única escritura permitida desde el front: marcar como leída una notificación
-- propia. La inserción la hacen siempre funciones security definer (server-side).
create policy "notificaciones update own"
  on public.notificaciones for update
  to authenticated
  using (destinatario_email = (select auth.jwt() ->> 'email'))
  with check (destinatario_email = (select auth.jwt() ->> 'email'));

alter publication supabase_realtime add table public.notificaciones;

create table public.recordatorios (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid references public.leads(id) on delete cascade,
  lead_privado_id uuid references public.leads_privados_tristan(id) on delete cascade,
  creado_por uuid references auth.users(id),
  creado_por_email text not null,
  tipo text not null default 'manual' check (tipo in ('manual','automatico')),
  fecha_disparo timestamptz not null,
  mensaje text not null default '',
  disparado boolean not null default false,
  created_at timestamptz not null default now(),
  check (num_nonnulls(lead_id, lead_privado_id) = 1)
);

create index recordatorios_pendientes_idx on public.recordatorios (fecha_disparo) where not disparado;

alter table public.recordatorios enable row level security;

-- La visibilidad de un recordatorio espeja la del lead al que apunta: si es
-- sobre un lead compartido, cualquier usuario autorizado; si es sobre un lead
-- de la Gestión Privada, solo Tristán.
create policy "recordatorios select"
  on public.recordatorios for select
  to authenticated
  using (
    (lead_id is not null and public.is_authorized_user())
    or (lead_privado_id is not null and public.is_tristan())
  );

create policy "recordatorios insert"
  on public.recordatorios for insert
  to authenticated
  with check (
    (lead_id is not null and public.is_authorized_user())
    or (lead_privado_id is not null and public.is_tristan())
  );

create policy "recordatorios delete"
  on public.recordatorios for delete
  to authenticated
  using (
    (lead_id is not null and public.is_authorized_user())
    or (lead_privado_id is not null and public.is_tristan())
  );

alter publication supabase_realtime add table public.recordatorios;

-- compartir_lead_tristan() ahora también avisa a Joaquín (in-app + email vía
-- el mismo pipeline de notificaciones) de que Tristán le compartió un lead.
create or replace function public.compartir_lead_tristan(p_lead_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new_id uuid;
  v_empresa text;
  v_joaquin_email text;
begin
  if not public.is_tristan() then
    raise exception 'Solo Tristán puede compartir leads de su Gestión Privada';
  end if;

  insert into public.leads (
    empresa, contacto, telefono, rubro, ticket, fuente, fecha_contacto,
    resultado, notas, etapa, archived, cierre, recontacto_active,
    recontacto_stage, recontacto_next_date, created_by
  )
  select
    empresa, contacto, telefono, rubro, ticket, fuente, fecha_contacto,
    resultado, notas, 'leads_tristan', archived, cierre, recontacto_active,
    recontacto_stage, recontacto_next_date, created_by
  from public.leads_privados_tristan
  where id = p_lead_id
    and trashed_at is null
  returning id, empresa into v_new_id, v_empresa;

  if v_new_id is null then
    raise exception 'Lead privado % no encontrado', p_lead_id;
  end if;

  delete from public.leads_privados_tristan where id = p_lead_id;

  select email into v_joaquin_email from public.usuarios_autorizados where rol = 'joaquin' limit 1;
  if v_joaquin_email is not null then
    insert into public.notificaciones (destinatario_email, tipo, lead_id, titulo, mensaje)
    values (
      v_joaquin_email, 'lead_compartido', v_new_id,
      'Tristán compartió un lead',
      'Tristán compartió "' || v_empresa || '" con vos — ya está en la columna Leads Tristán.'
    );
  end if;

  return v_new_id;
end;
$$;
