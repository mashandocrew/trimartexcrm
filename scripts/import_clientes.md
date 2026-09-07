# Import de cartera de clientes existentes (~60) — NO EJECUTAR TODAVÍA

Pendiente de que Joaquín pase las planillas ya revisadas/limpias. Cuando estén
listas, el flujo es:

1. Exportar la planilla limpia a CSV con estas columnas (en este orden):

   ```
   empresa,contacto,telefono,rubro,estado,notas
   ```

   - `rubro`: uno de `seguridad,limpieza,gastronomia,clubes,otro` (o vacío).
   - `estado`: `activo` o `inactivo`.
   - Si un cliente viene de un lead ya existente en el CRM y se quiere
     trazar el origen, hay que resolver `origen_lead_id` a mano (buscar el
     `id` del lead en la tabla `leads`) — no es parte de este CSV genérico.

2. Correr `scripts/import_clientes.sql` (ver abajo) contra el proyecto real,
   reemplazando la ruta del CSV. Usa una tabla de staging temporal y valida
   antes de insertar en `clientes` — no hace falta ningún script de Node ni
   dependencia nueva, alcanza con `psql`/el SQL Editor de Supabase.

3. Revisar el conteo de filas insertadas (`select count(*) from clientes;`)
   contra el número esperado de la planilla antes de dar el import por bueno.

Este import es aditivo e independiente del pipeline de `leads` — no toca
ninguna fila existente ahí.
