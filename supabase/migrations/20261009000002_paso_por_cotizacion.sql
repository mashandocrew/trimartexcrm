-- Trimartex CRM — un lead del pipeline compartido que llegó a "Cotización
-- pendiente" ya no puede pasar a la Gestión Privada de Tristán: Joaquín tiene
-- que ver todo el avance.
--
-- No alcanza con mirar la etapa actual: desde Cotización pendiente Tristán
-- puede mover el lead a "Leads Tristán" (es su zona) y devolverlo, o pasarlo a
-- Baja, mandarlo a Recontacto y sacarlo hacia privado. Por eso la regla es una
-- marca permanente, leads.paso_por_cotizacion: se prende al llegar a
-- Cotización pendiente o cualquier etapa posterior (Baja no cuenta: no es un
-- avance) y nunca se apaga, ni siquiera si el cliente la manda en false.
--
-- La hace cumplir un trigger BEFORE DELETE en leads (paso 4) sobre los dos
-- únicos caminos compartido -> privado: sacar_de_recontacto() y
-- devolver_lead_tristan() (también el "deshacer" de 40 s post-eliminación).
-- Joaquín sigue sin restricciones.
-- Los leads que Tristán avanza dentro de su propia Gestión Privada no se tocan.
--
-- Requiere 20261009000001.

-- 1) Marca permanente.
alter table public.leads
  add column if not exists paso_por_cotizacion boolean not null default false;

create or replace function public.trg_paso_por_cotizacion()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and old.paso_por_cotizacion then
    new.paso_por_cotizacion := true;
  end if;
  if new.etapa in ('cotizacion_pendiente', 'cotizacion_enviada', 'seguimiento', 'pedido_confirmado', 'entregado') then
    new.paso_por_cotizacion := true;
  end if;
  return new;
end;
$$;

revoke execute on function public.trg_paso_por_cotizacion() from public, anon, authenticated;

create or replace trigger leads_paso_por_cotizacion
  before insert or update on public.leads
  for each row execute function public.trg_paso_por_cotizacion();

-- 2) Las marcas internas (viene_de_recontacto, paso_por_cotizacion) no son un
--    movimiento del lead: un cambio que toca solo eso no pisa updated_at.
create or replace function public.trg_leads_set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_new jsonb := to_jsonb(new);
  v_old jsonb := to_jsonb(old);
begin
  if v_new ? 'viene_de_recontacto'
     and v_new is distinct from v_old
     and (v_new - 'viene_de_recontacto' - 'paso_por_cotizacion') = (v_old - 'viene_de_recontacto' - 'paso_por_cotizacion') then
    return new;
  end if;
  new.updated_at = now();
  return new;
end;
$$;

-- 3) Backfill: la etapa actual o cualquier paso previo registrado en el
--    historial.
update public.leads l
  set paso_por_cotizacion = true
  where not l.paso_por_cotizacion
    and (
      l.etapa in ('cotizacion_pendiente', 'cotizacion_enviada', 'seguimiento', 'pedido_confirmado', 'entregado')
      or exists (
        select 1 from public.lead_history h
        where h.lead_id = l.id
          and public.etapa_desde_label(h.label) in ('cotizacion_pendiente', 'cotizacion_enviada', 'seguimiento', 'pedido_confirmado', 'entregado')
      )
    );

-- 4) Guardián en la tabla: los dos caminos compartido -> privado
--    (sacar_de_recontacto() y devolver_lead_tristan(), también el "deshacer"
--    de 40 s) terminan borrando la fila de leads. Si quien lo hace es Tristán
--    y el lead pasó por Cotización pendiente, se rechaza y toda la operación
--    se revierte (incluida la copia que ya había insertado en privado).
--    Tristán no borra leads de forma definitiva por ningún otro camino: la
--    papelera es trashed_at y purge_trashed_leads() corre por pg_cron, sin
--    sesión. Joaquín no tiene restricciones.
create or replace function public.trg_bloquear_retiro_a_privado()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.paso_por_cotizacion and public.is_tristan() then
    raise exception 'Este lead ya pasó por Cotización pendiente: no puede pasar a la Gestión Privada';
  end if;
  return old;
end;
$$;

revoke execute on function public.trg_bloquear_retiro_a_privado() from public, anon, authenticated;

create or replace trigger leads_bloquear_retiro_a_privado
  before delete on public.leads
  for each row execute function public.trg_bloquear_retiro_a_privado();
