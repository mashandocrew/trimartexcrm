-- Trimartex CRM — carga del "Pedido a presupuestar" del lead Cafe Rossi.
-- Fuente: transcripción de llamada con Mariana Rossi (2026-11-05).
-- Solo completa leads.pedido_presupuestar. NO toca etapa ni ticket:
-- el monto estimado queda en 0 hasta tener lista de precios / presupuesto.
-- Ejecutar en el proyecto Supabase de Trimartex (SQL editor).

begin;

do $$
declare
  v_count int;
begin
  select count(*) into v_count
    from public.leads
   where empresa ilike 'cafe rossi'
     and trashed_at is null;
  if v_count <> 1 then
    raise exception 'Se esperaba 1 lead "Cafe Rossi" activo y hay %', v_count;
  end if;
end $$;

update public.leads
   set pedido_presupuestar = $pedido$
Pedido de Mariana Rossi (llamada 2026-11-05). Cantidades aproximadas, a confirmar.

PRENDAS
- Buzos con capucha y canguro, parte superior azul marino. Aprox. 4 unidades.
- Pantalones marrones. Aprox. 4 unidades.
- Remeras. Aprox. 4 unidades. Color [CONFIRMAR] (en la llamada no quedó claro si son azul marino, blancas o negras).
- Un empleado no tiene buzo: se pidió resolverlo rápido [CONFIRMAR si es prioritario].

LOGO
- Nuevo logo de café: flor marrón con la palabra "Rossi" debajo.
- Dos colores (marrón oscuro y [CONFIRMAR]), fondo blanco.
- Ubicación en buzo: pecho adelante grande, lado izquierdo, manga, y a veces espalda en la nuca. [CONFIRMAR cuáles.]

LO QUE PIDE EL CLIENTE
- Presupuesto. Compara primero por precio y después por calidad.
- Muestra del buzo con canguro para ver calidad, con fotos.
- Tiene otros proveedores en evaluación.
- No es urgente.

PENDIENTE
- Ticket estimado: [CONFIRMAR] (no hay precios cargados).
- Cuándo se envía el presupuesto y la muestra: [CONFIRMAR].
$pedido$
 where empresa ilike 'cafe rossi'
   and trashed_at is null;

commit;
