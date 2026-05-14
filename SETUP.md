# Álbum México — Setup paso a paso

## Cosas a tener listas (15 min)

1. **Cuenta Supabase** — https://supabase.com → crea un proyecto nuevo. Anota:
   - `SUPABASE_URL` (algo como `https://abcd.supabase.co`)
   - `SUPABASE_ANON_KEY` (Settings → API → anon public)
   - `SUPABASE_SERVICE_ROLE_KEY` (Settings → API → service_role — **secret**)

2. **Cuenta Resend** — https://resend.com → API Keys → New. Anota la `RESEND_API_KEY` (empieza con `re_`).

3. **Node.js** instalado (20+).

4. **CLI de Supabase** para deployar la Edge Function. El CLI ya no soporta `npm install -g`; usa Homebrew (macOS/Linux):
   ```bash
   brew install supabase/tap/supabase
   ```
   En Windows: descarga el binario desde https://github.com/supabase/cli/releases

5. Tu archivo `escapadas-index.json` (el que ya tienes).

## Paso 1 — Sembrar la base de datos

1. Abre Supabase → SQL Editor → New Query.
2. Pega el contenido de `supabase-schema.sql` completo.
3. Run. Va a crear: tablas, RLS, función `match_with_user`, y los 32 estados con sus regiones.
4. Verifica en Table Editor → `states` que aparezcan los 32.

Ahora los ~250 destinos. Usa el script Node:

```bash
npm init -y
npm install @supabase/supabase-js ws   # ws es necesario en Node 20 (sin WebSocket nativo)

cat > .env <<EOF
SUPABASE_URL=https://TU_PROYECTO.supabase.co
SUPABASE_SERVICE_KEY=eyJhbGc...   # service_role, NO anon
EOF

node --env-file=.env seed-places.mjs escapadas-index.json
```

Debería imprimir algo como:
```
Encontrados 310 destinos en el JSON
Estados en DB: 32
  100/310 subidos
  ...
Listo. 310 destinos cargados.
Pueblos Mágicos: 177
```

## Paso 2 — Configurar Auth y desplegar la Edge Function

En el dashboard de Supabase:

1. **Authentication → Providers → Email** — actívalo. Desactiva "Confirm email" (no lo necesitamos, magic link es la confirmación).
2. **Authentication → URL Configuration** — agrega en **Redirect URLs**:
   - `http://localhost:5173/album-mexico.html` (dev)
   - Tu URL de producción cuando exista (ej. `https://tu-album.com/album-mexico.html`)

Deploy de la Edge Function:

```bash
supabase login                           # abre el browser
supabase link --project-ref TU_PROYECTO  # los primeros chars del URL del dashboard
supabase functions deploy send-magic-link --no-verify-jwt
```

Guarda todos los secretos de la función en un solo comando:

```bash
supabase secrets set \
  RESEND_API_KEY=re_TU_KEY_RESEND \
  REDIRECT_URL=http://localhost:5173/album-mexico.html \
  FROM_ADDRESS=onboarding@resend.dev \
  FROM_NAME='Álbum México'
```

> **Importante:** `REDIRECT_URL` debe apuntar al HTML exacto (`/album-mexico.html`), no solo al root del servidor — de lo contrario el magic link redirige a un directorio vacío.

> **Importante con `onboarding@resend.dev`**: ese dominio sandbox de Resend **solo manda correos al email registrado en tu cuenta Resend**. Para mandar a cualquier persona, tienes que verificar un dominio propio en Resend → Domains. Mientras pruebas tú mismo, funciona.

## Paso 3 — Probar la Edge Function

```bash
curl -X POST 'https://TU_PROYECTO.supabase.co/functions/v1/send-magic-link' \
  -H 'apikey: TU_ANON_KEY' \
  -H 'Authorization: Bearer TU_ANON_KEY' \
  -H 'Content-Type: application/json' \
  -d '{"email":"tu-correo@gmail.com"}'
```

Esperado: `{"ok":true}` + correo en tu inbox en ~10 segundos.

Si falla, ve los logs:
```bash
supabase functions logs send-magic-link --tail
```

## Paso 4 — Frontend

El archivo `album-mexico.html` se conecta a tu Supabase. Solo edita las dos constantes arriba del script:

```js
const SUPABASE_URL  = 'https://TU_PROYECTO.supabase.co'
const SUPABASE_ANON = 'eyJ...'   // anon public key
```

Para correr localmente sin servidor (el más simple):
```bash
python3 -m http.server 5173
# abre http://localhost:5173/album-mexico.html
```

O con cualquier dev server. Cuando estés listo:
- Sube el HTML a **Cloudflare Pages** o **Vercel** (drop & drop)
- Actualiza `REDIRECT_URL` en los secretos de la Edge Function al dominio real
- Actualiza el `Access-Control-Allow-Origin` en la Edge Function de `*` a tu dominio

## Costos esperados primer año

| Usuarios activos | Correos/mes | Supabase | Resend | Total |
|---|---|---|---|---|
| Lanzamiento (50/mes) | ~150 | $0 | $0 | **$0** |
| Crecimiento (500/mes) | ~1,500 | $0 | $0 | **$0** |
| Escalar (5,000/mes) | ~15,000 | $25 (Pro) | $20 | **$45/mes** |

## Tres cosas que vale activar después

1. **Realtime** — Supabase tiene WebSockets gratis. Para "🔥 personas marcando ahora mismo".
2. **Storage** — Si los usuarios suben fotos de sus visitas, va aquí. 1 GB gratis.
3. **pg_cron** — Para mandar resumen semanal por correo ("Esta semana 5 amigos marcaron lugares nuevos").

Ninguno hace falta para el MVP.

## Cuando tengas dominio propio para los correos

En Resend → Domains → Add. Te pide agregar 3-4 registros DNS (SPF, DKIM, MX opcional). Una vez verificado, cambia `FROM_ADDRESS`:

```bash
supabase secrets set FROM_ADDRESS=hola@tu-dominio.com
```

Y listo, los correos llegan desde tu marca.
