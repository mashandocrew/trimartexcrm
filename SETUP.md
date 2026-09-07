# Trimartex CRM — Setup del backend Supabase

Este documento cubre lo que hace falta para que `trimartex-crm.html` corra
contra el proyecto real de Supabase (`yvjxftmfjoxajjryxabo`, región
`sa-east-1`) en vez de `localStorage`.

## 1. Estado actual

Ya aplicado contra el proyecto real (ver `supabase/migrations/`):

- Schema completo: `leads`, `lead_history`, `clientes`, `usuarios_autorizados`,
  enums de rubro/resultado/etapa/cierre/estado_cliente.
- RLS en las 4 tablas: sin sesión válida y allowlisteada, cero acceso (probado
  contra el proyecto real con la anon key sin sesión: `SELECT` devuelve `[]`,
  `INSERT` devuelve `401` con `"new row violates row-level security policy"`).
- Trigger de auditoría server-side: cualquier `INSERT`/`UPDATE` relevante en
  `leads` genera automáticamente filas en `lead_history` — el frontend nunca
  escribe historial a mano.
- Papelera: `pg_cron` corre `purge_trashed_leads()` todos los días a las 03:00
  (America/Argentina) y borra en serio lo que lleva +7 días con `trashed_at`
  seteado.
- Realtime habilitado en `leads` y `lead_history`.
- Allowlist cargada: `joaquin.23.ponce@gmail.com` (rol `joaquin`) y
  `tristan.gonzalez@gmail.com` (rol `tristan`).
- Advisors de seguridad de Supabase revisados: sin warnings pendientes salvo
  uno intencional (`is_authorized_user()` es ejecutable por `authenticated`
  porque las políticas RLS la invocan en ese contexto; la función solo
  devuelve `true/false` sobre el propio caller, no expone datos de otros).

Lo que **falta hacer a mano**, porque requiere acceso a cuentas externas que
esta sesión no tiene (Google Cloud Console, dashboard de Vercel):

## 2. Configurar el proveedor de Google en Supabase (obligatorio para el login)

1. En [Google Cloud Console](https://console.cloud.google.com/), creá un
   OAuth Client ID de tipo "Web application".
   - Authorized redirect URI: `https://yvjxftmfjoxajjryxabo.supabase.co/auth/v1/callback`
2. En el [dashboard de Supabase](https://supabase.com/dashboard/project/yvjxftmfjoxajjryxabo/auth/providers) →
   Authentication → Providers → Google: pegá el Client ID y el Client Secret,
   activá el proveedor.
3. En Authentication → URL Configuration, agregá la URL de producción de
   Vercel (y `http://localhost:3000` o el puerto que uses en local) a
   **Redirect URLs**.

Sin este paso, el botón "Continuar con Google" del login falla.

## 3. Variables de entorno en Vercel

El archivo no usa bundler — es un único `.html`. Un build command
(`build-env.sh`, ya en el repo) genera `env.js` a partir de las env vars en
build time, y `trimartex-crm.html` lo carga como `window.__ENV` antes de
inicializar el cliente de Supabase.

En el proyecto de Vercel, configurá:

| Variable | Valor |
|---|---|
| `SUPABASE_URL` | `https://yvjxftmfjoxajjryxabo.supabase.co` |
| `SUPABASE_ANON_KEY` | La "anon" key del proyecto (Project Settings → API en el dashboard de Supabase) |

`vercel.json` ya apunta el `buildCommand` a `bash build-env.sh` y reescribe `/`
a `/trimartex-crm.html`. No hace falta tocar nada más ahí.

Ni `SUPABASE_URL` ni `SUPABASE_ANON_KEY` son secretos — la protección real de
los datos es RLS, no ocultar estas dos strings — pero igual quedan fuera del
repo (vía env vars + `env.js` generado, gitignoreado) en vez de hardcodeadas
en el HTML, para no tener que tocar código si cambian.

## 4. Correr en local

```bash
cp env.js.example env.js
# editá env.js con la anon key real (Project Settings → API en Supabase)
python3 -m http.server 8000
# abrí http://localhost:8000/trimartex-crm.html
```

`env.js` está en `.gitignore`, nunca se commitea.

Para que el login de Google funcione en local, agregá
`http://localhost:8000` a las Redirect URLs de Supabase (paso 2).

## 5. Agregar o quitar gente de la allowlist

No hay UI para esto a propósito (son 2 usuarios). Se edita directo en el SQL
Editor del dashboard de Supabase, o con una nueva migración:

```sql
-- agregar
insert into public.usuarios_autorizados (email, rol) values ('nueva@persona.com', 'joaquin');

-- quitar acceso (no borra sus leads ni su historial, solo el acceso)
delete from public.usuarios_autorizados where email = 'alguien@ejemplo.com';
```

`rol` solo acepta `'joaquin'` o `'tristan'` — determina automáticamente qué
etapas del pipeline ve esa persona al loguearse (ya no hay toggle manual en
el header).

## 6. Decisiones de negocio ya definidas (no volver a preguntar)

- Modo (Joaquín/Tristán) se asigna automáticamente por la cuenta de Google
  que inició sesión, leyendo `rol` de `usuarios_autorizados`.
- Alertas de recontacto vencido: solo indicador visual dentro del CRM (badge
  rojo "Vencido" en la card cuando `recontacto_next_date` ya pasó). Sin
  email/WhatsApp externo.
- `clientes` es una tabla separada de `leads` (no flags `es_cliente` /
  `estado_cliente` sobre `leads`). Tiene `origen_lead_id` opcional para
  trazar qué lead se convirtió en cliente.

## 7. Auto-test (checklist de la sección 6 del prompt original)

- [x] Sin sesión, la anon key no puede leer ni escribir en `leads` ni
      `lead_history` — probado contra el proyecto real con `curl` (ver arriba).
- [ ] Una cuenta de Google que no está en `usuarios_autorizados` no accede a
      ningún dato — el frontend hace el chequeo y cierra sesión
      automáticamente si no hay fila en `usuarios_autorizados`; falta probar
      con una cuenta de Google real una vez configurado el paso 2.
- [x] Cambiar la etapa de un lead genera una fila en `lead_history` sin que
      el front haga nada extra — probado contra el proyecto real: un lead de
      prueba pasó por 5 updates (etapa, cierre, recontacto) hechos por SQL
      puro, sin ningún insert manual a `lead_history`, y las 7 filas de
      historial (incluida "Lead creado") aparecieron solas, con
      `recontacto_next_date` bien calculado en cada paso.
- [x] "Eliminar" un lead no lo borra de la tabla — solo setea `trashed_at`.
- [x] Un lead con `trashed_at` de +7 días se borra solo — probado contra el
      proyecto real: se puso `trashed_at = now() - interval '8 days'` en el
      lead de prueba, se corrió `select purge_trashed_leads();` a mano (el
      cron real corre solo, diario 03:00 ART) y el lead (con su historial en
      cascada) desapareció.
- [x] Realtime habilitado en `leads` y `lead_history` — falta la prueba
      manual con dos sesiones abiertas en simultáneo una vez deployado.
- [x] El front conserva el diseño y la interacción de la versión localStorage
      (drag&drop, modales, tabs mobile, WhatsApp) — se reescribió solo la
      capa de datos, no el HTML/CSS/interacción.
- [ ] Build limpio en Vercel con las env vars de este documento — pendiente
      del primer deploy.

## 8. Import de la cartera de clientes (~60) — documentado, sin ejecutar

Ver `scripts/import_clientes.md`. No corre nada hasta que pases las
planillas ya revisadas.

## 9. Nota sobre el CDN de supabase-js

El HTML carga `@supabase/supabase-js` pinneado a la versión `2.45.4` desde
jsdelivr (sin bundler). Si en algún momento se agrega un pipeline de build,
conviene instalarlo como dependencia npm real e importarlo con SRI hash o
bundlearlo, en vez de depender del CDN.
