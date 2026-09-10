-- Trimartex CRM — Gestión Privada de Tristán.
--
-- Tabla separada (mismo shape que public.leads) para los leads que Tristán
-- carga por su cuenta y que Joaquín NO debe ver hasta que Tristán decida
-- compartirlos. Se mantiene separada de leads (en vez de una columna
-- "espacio" en la misma tabla) para que las policies de RLS de leads no
-- tengan que distinguir fila por fila.
--
-- El toggle "Gestión Privada" del frontend usa la misma UI de Kanban y de
-- recontacto que el pipeline compartido, apuntando a esta tabla en lugar de
-- a leads. La etapa 'leads_tristan' NO se usa acá (no tiene sentido en un
-- espacio privado) — se usa recién en public.leads cuando el lead se comparte.

create table public.leads_privados_tristan (
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

create index leads_privados_tristan_etapa_idx on public.leads_privados_tristan (etapa) where trashed_at is null and archived = false;
create index leads_privados_tristan_recontacto_idx on public.leads_privados_tristan (recontacto_active, recontacto_stage) where trashed_at is null and archived = false;

-- Reutiliza los mismos triggers genéricos de leads (no referencian el nombre
-- de tabla, así que sirven tal cual).
create trigger leads_privados_tristan_set_updated_at
  before update on public.leads_privados_tristan
  for each row
  execute function public.trg_leads_set_updated_at();

create trigger leads_privados_tristan_recontacto_next_date
  before insert or update on public.leads_privados_tristan
  for each row
  execute function public.trg_leads_recontacto_next_date();

-- Sin trigger de auditoría: lead_history.lead_id referencia public.leads(id)
-- on delete cascade, y esta tabla es privada de Tristán — no hay
-- requerimiento de bitácora para leads que todavía no se compartieron.

alter table public.leads_privados_tristan enable row level security;

-- Solo Tristán puede ver/escribir. Sin policy de DELETE (mismo patrón de
-- papelera soft-delete que leads: "Eliminar" en el front pone trashed_at).
create or replace function public.is_tristan()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.usuarios_autorizados u
    where u.email = (select auth.jwt() ->> 'email')
      and u.rol = 'tristan'
  );
$$;

revoke execute on function public.is_tristan() from public;
grant execute on function public.is_tristan() to authenticated;

create policy "leads_privados_tristan select if tristan"
  on public.leads_privados_tristan for select
  to authenticated
  using (public.is_tristan());

create policy "leads_privados_tristan insert if tristan"
  on public.leads_privados_tristan for insert
  to authenticated
  with check (public.is_tristan());

create policy "leads_privados_tristan update if tristan"
  on public.leads_privados_tristan for update
  to authenticated
  using (public.is_tristan())
  with check (public.is_tristan());

alter publication supabase_realtime add table public.leads_privados_tristan;

-- etapa_label() no contemplaba 'leads_tristan' (agregada en la migración
-- anterior) — sin este fix, el frontend recibiría NULL como label si algún
-- día se muestra el nombre de etapa vía esta función.
create or replace function public.etapa_label(e public.etapa_enum)
returns text
language sql
immutable
as $$
  select case e
    when 'leads_tristan' then 'Leads Tristán'
    when 'nuevo' then 'Nuevo'
    when 'contactado' then 'Contactado'
    when 'cotizacion_pendiente' then 'Cotización pendiente'
    when 'cotizacion_enviada' then 'Presupuesto enviado'
    when 'seguimiento' then 'Seguimiento'
    when 'cerrado' then 'Cerrado'
  end;
$$;

-- Mover un lead de la Gestión Privada de Tristán al pipeline compartido:
-- inserta la fila en leads con etapa = 'leads_tristan' y borra el original
-- de la tabla privada (ya no tiene sentido conservarlo ahí duplicado).
-- security definer porque el caller (Tristán) no tiene INSERT en
-- lead_history ni motivo para tocar leads directamente con este shape.
create or replace function public.compartir_lead_tristan(p_lead_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new_id uuid;
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
  returning id into v_new_id;

  if v_new_id is null then
    raise exception 'Lead privado % no encontrado', p_lead_id;
  end if;

  delete from public.leads_privados_tristan where id = p_lead_id;

  return v_new_id;
end;
$$;

revoke execute on function public.compartir_lead_tristan(uuid) from public, anon;
grant execute on function public.compartir_lead_tristan(uuid) to authenticated;
