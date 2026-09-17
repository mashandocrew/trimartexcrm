-- Trimartex CRM — novedades de contacto en todas las etapas y en los dos espacios.
--
-- Hasta acá lead_novedades solo podía colgar de public.leads, así que la
-- bitácora existía únicamente en el pipeline compartido (y el frontend
-- además la mostraba solo en la etapa "contactado"). El pedido es que
-- agregar novedades esté disponible en TODAS las etapas y también en la
-- Gestión Privada de Tristán.
--
-- Se agrega lead_privado_id (referencia a leads_privados_tristan) y lead_id
-- pasa a ser nullable: cada fila cuelga de exactamente uno de los dos
-- espacios. Se mantiene el carácter append-only (sin policies de UPDATE ni
-- DELETE) — una novedad ya cargada no se edita ni se borra.

alter table public.lead_novedades
  add column lead_privado_id uuid references public.leads_privados_tristan(id) on delete cascade;

alter table public.lead_novedades
  alter column lead_id drop not null;

alter table public.lead_novedades
  add constraint lead_novedades_un_solo_espacio
  check (num_nonnulls(lead_id, lead_privado_id) = 1);

create index lead_novedades_lead_privado_id_idx
  on public.lead_novedades (lead_privado_id, contactado_at desc);

-- Las novedades de un lead privado son tan privadas como el lead: solo
-- Tristán las ve y las escribe. Las del pipeline compartido siguen igual.
drop policy "lead_novedades select if authorized" on public.lead_novedades;
drop policy "lead_novedades insert if authorized" on public.lead_novedades;

create policy "lead_novedades select segun espacio"
  on public.lead_novedades for select
  to authenticated
  using (
    case when lead_privado_id is null
      then public.is_authorized_user()
      else public.is_tristan()
    end
  );

create policy "lead_novedades insert segun espacio"
  on public.lead_novedades for insert
  to authenticated
  with check (
    case when lead_privado_id is null
      then public.is_authorized_user()
      else public.is_tristan()
    end
  );
