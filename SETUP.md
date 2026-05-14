# Álbum México — Setup paso a paso

## Cosas a tener listas (15 min)

1. **Cuenta Supabase** — https://supabase.com → crea un proyecto nuevo. Anota:
   - `SUPABASE_URL` (algo como `https://abcd.supabase.co`)
   - `SUPABASE_ANON_KEY` (Settings → API → anon public)
   - `SUPABASE_SERVICE_ROLE_KEY` (Settings → API → service_role — **secret**)

2. **Cuenta Resend** — https://resend.com → API Keys → New. Anota la `RESEND_API_KEY` (empieza con `re_`).

3. **Node.js** instalado (cualquier 18+).

4. **CLI de Supabase** para deployar la Edge Function:
   ```bash
   npm install -g supabase
   ```

5. Tu archivo `escapadas-index.json` (el que ya tienes).

## Paso 1 — Sembrar la base de datos

1. Abre Supabase → SQL Editor → New Query.
2. Pega el contenido de `supabase-schema.sql` completo.
3. Run. Va a crear: tablas, RLS, función `match_with_user`, y los 32 estados con sus regiones.
4. Verifica en Table Editor → `states` que aparezcan los 32.

Ahora los ~250 destinos. Usa el script Node:

```bash
cd album-mexico
npm init -y
npm install @supabase/supabase-js

cat > .env <<EOF
SUPABASE_URL=https://TU_PROYECTO.supabase.co
SUPABASE_SERVICE_KEY=eyJhbGc...   # service_role, NO anon
EOF

node --env-file=.env seed-places.mjs /ruta/a/escapadas-index.json
```

Debería imprimir:
```
Encontrados 250 destinos en el JSON
Estados en DB: 32
  100/250 subidos
  200/250 subidos
  250/250 subidos
Listo. 250 destinos cargados.
Pueblos Mágicos: 135
```

## Paso 2 — Configurar Auth y desplegar la Edge Function

En el dashboard de Supabase:

1. **Authentication → Providers → Email** — actívalo. Desactiva "Confirm email" (no lo necesitamos, magic link es la confirmación).
2. **Authentication → URL Configuration** — agrega tu(s) Site URL: localhost para dev (`http://localhost:5173`) y producción cuando exista.

Deploy de la Edge Function:

```bash
cd album-mexico
supabase login                           # abre el browser
supabase link --project-ref TU_PROYECTO  # del URL del dashboard
supabase functions deploy send-magic-link --no-verify-jwt
```

Guarda los secretos de la función:

```bash
supabase secrets set RESEND_API_KEY=re_TU_KEY_RESEND
supabase secrets set REDIRECT_URL=http://localhost:5173    # cámbialo en producción
supabase secrets set FROM_ADDRESS=onboarding@resend.dev    # sandbox para arrancar
supabase secrets set FROM_NAME='Álbum México'
```

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
