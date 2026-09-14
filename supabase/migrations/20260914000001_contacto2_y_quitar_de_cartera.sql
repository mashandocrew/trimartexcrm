-- Trimartex CRM — contacto secundario + "Eliminar de cartera" al enviar como lead.
--
-- Contacto secundario: columnas nullable (nombre, teléfono) en las tres tablas
-- que cargan contactos. Columnas y no tabla 1-a-muchos: el negocio pide un
-- solo contacto extra, y con tres tablas padre distintas una tabla contactos
-- obligaría a FKs polimórficas.
--
-- clientes.trashed_at: soft delete que usa "Enviar como lead" → "Eliminar de
-- cartera". El botón "Eliminar" del modal de cliente no cambia.
--
-- RLS sin cambios: la Gestión Privada sigue protegida por is_tristan() en su
-- propia tabla; leads y clientes siguen compartidos entre ambos roles.

alter table public.leads
  add column if not exists contacto2_nombre text,
  add column if not exists contacto2_telefono text;

alter table public.leads_privados_tristan
  add column if not exists contacto2_nombre text,
  add column if not exists contacto2_telefono text;

alter table public.clientes
  add column if not exists contacto2_nombre text,
  add column if not exists contacto2_telefono text,
  add column if not exists trashed_at timestamptz;

create index if not exists clientes_activos_empresa_idx
  on public.clientes (empresa) where trashed_at is null;

-- Al compartir un lead privado ahora viajan también el contacto secundario y
-- la clasificación ABC (que antes se perdía al compartir).
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
    empresa, contacto, telefono, contacto2_nombre, contacto2_telefono, rubro,
    ticket, fuente, fecha_contacto, resultado, notas, etapa, archived, cierre,
    recontacto_active, recontacto_stage, recontacto_next_date,
    clasificacion_abc, created_by
  )
  select
    empresa, contacto, telefono, contacto2_nombre, contacto2_telefono, rubro,
    ticket, fuente, fecha_contacto, resultado, notas, 'leads_tristan', archived, cierre,
    recontacto_active, recontacto_stage, recontacto_next_date,
    clasificacion_abc, created_by
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
