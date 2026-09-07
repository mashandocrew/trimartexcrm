-- Trimartex CRM — server-side audit trail and housekeeping triggers.
--
-- The frontend never writes to lead_history directly. Every entry — lead
-- creation, stage changes, cierre tagging, recontacto transitions — is
-- produced here, so the audit trail can't be skipped or faked by a client bug.

create or replace function public.trg_leads_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger leads_set_updated_at
  before update on public.leads
  for each row
  execute function public.trg_leads_set_updated_at();

create trigger clientes_set_updated_at
  before update on public.clientes
  for each row
  execute function public.trg_leads_set_updated_at();

-- Recalculates recontacto_next_date (today + 7) whenever recontacto_stage
-- changes or recontacto gets (re)activated, so the frontend can flag leads
-- whose next follow-up date has passed without recomputing anything itself.
create or replace function public.trg_leads_recontacto_next_date()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    if new.recontacto_active then
      new.recontacto_next_date = current_date + 7;
    end if;
    return new;
  end if;

  if new.recontacto_active and (
    not old.recontacto_active
    or old.recontacto_stage is distinct from new.recontacto_stage
  ) then
    new.recontacto_next_date = current_date + 7;
  elsif not new.recontacto_active and old.recontacto_active then
    new.recontacto_next_date = null;
  end if;

  return new;
end;
$$;

create trigger leads_recontacto_next_date
  before insert or update on public.leads
  for each row
  execute function public.trg_leads_recontacto_next_date();

create or replace function public.etapa_label(e public.etapa_enum)
returns text
language sql
immutable
as $$
  select case e
    when 'nuevo' then 'Nuevo'
    when 'contactado' then 'Contactado'
    when 'cotizacion_pendiente' then 'Cotización pendiente'
    when 'cotizacion_enviada' then 'Presupuesto enviado'
    when 'seguimiento' then 'Seguimiento'
    when 'cerrado' then 'Cerrado'
  end;
$$;

create or replace function public.trg_leads_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.lead_history (lead_id, label, created_by)
    values (new.id, 'Lead creado', auth.uid());
    return new;
  end if;

  -- tg_op = 'UPDATE'
  if old.etapa is distinct from new.etapa then
    insert into public.lead_history (lead_id, label, created_by)
    values (
      new.id,
      case when new.etapa = 'cotizacion_enviada'
        then 'Presupuesto enviado'
        else 'Cambió a ' || public.etapa_label(new.etapa)
      end,
      auth.uid()
    );
  end if;

  if old.cierre is distinct from new.cierre then
    insert into public.lead_history (lead_id, label, created_by)
    values (
      new.id,
      case
        when new.cierre = 'cerrado' then 'Marcado como Cerrado'
        when new.cierre = 'no_cerrado' then 'Marcado como No cerrado'
        else 'Estado de cierre sin definir'
      end,
      auth.uid()
    );
  end if;

  if old.recontacto_active is distinct from new.recontacto_active then
    insert into public.lead_history (lead_id, label, created_by)
    values (
      new.id,
      case when new.recontacto_active
        then 'Enviado a Recontacto (semana ' || new.recontacto_stage || ')'
        else 'Sacado de Recontacto'
      end,
      auth.uid()
    );
  elsif new.recontacto_active and old.recontacto_stage is distinct from new.recontacto_stage then
    insert into public.lead_history (lead_id, label, created_by)
    values (new.id, 'Recontacto: semana ' || new.recontacto_stage, auth.uid());
  end if;

  return new;
end;
$$;

create trigger leads_audit
  after insert or update on public.leads
  for each row
  execute function public.trg_leads_audit();
