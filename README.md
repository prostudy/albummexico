# Álbum México

Pasaporte digital de viajero: marca los 32 estados y ~310 destinos de México como **quiero ir**, **visitado** o **lo amé**. Comparte tu álbum, compara destinos con amigos.

**Stack:** HTML estático + Vue CDN · Supabase (Postgres + Auth + Edge Functions) · Cloudflare Pages · Cloudflare R2 · Resend

---

## Arquitectura de producción

```
Usuario
  │
  ▼
Cloudflare Pages          ← album-mexico.html (CDN global, gratis)
  │
  ├── API calls ──────►  Supabase              ← Postgres + RLS + Auth
  │                        └─ Edge Function    ← send-magic-link (Deno)
  │
  └── Imágenes ─────►  Cloudflare R2           ← 10 GB storage, 0 egress
                          └─ CDN Cloudflare    ← misma red, sin latencia extra

Emails ────────────────►  Resend               ← magic links
```

### Por qué este stack y no otro

| Decisión | Motivo |
|---|---|
| Cloudflare Pages vs Vercel | El app es un solo HTML estático. CF tiene más PoPs en México/LATAM y R2 está en la misma red. |
| R2 vs Supabase Storage | R2 tiene 0 egress (Supabase Storage cobra por transferencia en el free tier). Para ~5K imágenes servidas frecuentemente, la diferencia es grande. |
| Cloudflare Pages vs GitHub Pages | Pages tiene preview deployments, redirects nativos, y variables de entorno desde el panel. |

### Límites del free tier vs tráfico esperado

```
Supabase free:   50K usuarios activos/mes  →  ~10K usuarios diarios ✓
Supabase BW:      5 GB/mes de API          →  ~17 KB/sesión promedio ✓
Cloudflare R2:   10 GB storage             →  ~5K imágenes ✓ (0 egress siempre)
Cloudflare Pages: bandwidth ilimitado      →  sin tope ✓
Resend free:     100 correos/día           →  ~30 registros nuevos/día ✓
```

---

## Setup inicial

Ver [SETUP.md](SETUP.md) para crear Supabase, sembrar la base de datos y deployar la Edge Function.

---

## Desarrollo local

### Cómo correr el proyecto localmente

El app es un HTML estático — no necesita servidor Node ni build step. Sirve la carpeta del proyecto con cualquier servidor local:

**Con MAMP (configuración actual):**
```
http://localhost:8888/album_cdmx/index.html
```

**Con Python (alternativa sin instalar nada):**
```bash
python3 -m http.server 5173
# abre http://localhost:5173/index.html
```

### Magic link en desarrollo local

La Edge Function detecta automáticamente desde qué URL se llama y ajusta el `redirectTo` del magic link. No hay que cambiar ningún secret al trabajar local.

Orígenes configurados en `supabase/functions/send-magic-link/index.ts`:

| Entorno | URL del sitio | Magic link redirige a |
|---|---|---|
| MAMP local | `http://localhost:8888` | `http://localhost:8888/album_cdmx/index.html` |
| Vite / dev server | `http://localhost:5173` | `http://localhost:5173/index.html` |
| Producción | `https://yafui.guru` | `https://yafui.guru/index.html` |

Para que Supabase acepte los redirects locales, agrega estas URLs en:  
**Supabase → Authentication → URL Configuration → Redirect URLs:**
```
http://localhost:8888/album_cdmx/index.html
http://localhost:5173/index.html
https://yafui.guru/index.html
https://albummexico.pages.dev/index.html
```

Si cambias de puerto o ruta local, edita el objeto `ORIGINS` en la Edge Function y vuelve a hacer deploy:
```bash
supabase functions deploy send-magic-link --no-verify-jwt
```

---

## Deploy a Cloudflare Pages

> **Sitio en producción:** `https://yafui.guru`

### Cómo se hizo (drop & deploy)

El proyecto se subió directamente como archivo estático, sin conectar GitHub ni configurar build commands. Pasos exactos:

1. Dashboard de Cloudflare → **Workers & Pages** → **Create application**
2. En la pantalla "Ship something new" → **Upload your static files**
   - ⚠️ Si no ves esa opción, busca al fondo de la pantalla el link **"Looking to deploy Pages? Get started"**
   - No usar "Continue with GitHub" desde esa pantalla — crea un proyecto Workers, no Pages
3. El archivo en el repo se llama `album-mexico.html` — **renombrarlo a `index.html`** antes de subir
   - Sin este renombre, la raíz `/` devuelve 404
4. Arrastrar `index.html` al uploader → **Deploy site**
5. En ~30 segundos el sitio queda live en `https://albummexico.pages.dev` (custom domain: `https://yafui.guru`)

### Para futuros deploys (cuando cambies el HTML)

1. Renombrar `album-mexico.html` → `index.html`
2. Cloudflare Pages → proyecto `albummexico` → **Create new deployment**
3. Arrastrar el nuevo `index.html`

### Opción alternativa — GitHub (para deploys automáticos)

Si en el futuro quieres que cada push a `main` haga deploy automático:

1. Workers & Pages → Create application → **Pages** → **Connect to Git**
2. Selecciona el repo. Configuración:
   - **Framework preset:** None
   - **Build command:** *(vacío)*
   - **Build output directory:** `.`
3. Cloudflare detecta el `index.html` en la raíz y lo sirve automáticamente.

---

## Migración de imágenes a Cloudflare R2

Las imágenes actuales son hotlinks a WordPress de Mexico Desconocido. Migrarlas a R2 las pone en la red de Cloudflare (misma que sirve tu app) y elimina la dependencia de un tercero.

### 1. Crear el bucket R2

En el [dashboard de Cloudflare](https://dash.cloudflare.com) → R2 → Create bucket. Nombre sugerido: `album-mexico-images`.

Activa acceso público: Settings → Public access → Allow.

Copia el **endpoint público** (algo como `https://pub-xxxx.r2.dev`) — lo usarás como `R2_PUBLIC_URL`.

### 2. Credenciales R2

R2 usa la API compatible con S3. Ve a R2 → Manage R2 API tokens → Create API token:
- Permissions: Object Read & Write
- Specify bucket: `album-mexico-images`

Anota:
- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`
- `R2_ACCOUNT_ID` (está en la URL del dashboard: `dash.cloudflare.com/<ACCOUNT_ID>/r2`)

### 3. Instalar dependencia S3

```bash
npm install @aws-sdk/client-s3
```

### 4. Correr el script de migración

```bash
cat >> .env <<EOF
R2_ACCESS_KEY_ID=tu_access_key
R2_SECRET_ACCESS_KEY=tu_secret_key
R2_ACCOUNT_ID=tu_account_id
R2_BUCKET=album-mexico-images
R2_PUBLIC_URL=https://pub-xxxx.r2.dev
EOF

node --env-file=.env migrate-images-r2.mjs
```

El script (`migrate-images-r2.mjs`, incluido en este repo) hace:
1. Lee todas las filas de `states` y `places` en Supabase
2. Descarga cada imagen del URL original
3. La sube a R2 con el mismo nombre de archivo
4. Actualiza el `image_url` en Supabase al URL de R2
5. Salta las que ya existen en R2 (idempotente)

Salida esperada:
```
[states] 32 imágenes a procesar
  ✓ aguascalientes.jpg  →  https://pub-xxxx.r2.dev/states/aguascalientes.jpg
  ...
[places] 310 imágenes a procesar
  ✓ san-cristobal.jpg   →  https://pub-xxxx.r2.dev/places/san-cristobal.jpg
  ...
Listo. 342 imágenes migradas, 0 errores.
```

### 5. Verificar

Abre tu app en Cloudflare Pages. Las imágenes deben cargar desde `pub-xxxx.r2.dev` (o tu dominio custom si ya lo configuraste). Puedes verificar en DevTools → Network → filtrar por `Img`.

---

## Dominio propio (opcional)

### Para el sitio

En Cloudflare Pages → Custom domains → agrega `yafui.guru`. Si el dominio está en Cloudflare, se configura solo. Si está en otro registrador, agrega el CNAME que te indica.

### Para las imágenes en R2

En R2 → tu bucket → Settings → Custom domain. Agrega `img.yafui.guru`. Cloudflare crea el registro DNS automáticamente si el dominio está en tu cuenta.

Actualiza `R2_PUBLIC_URL` en `.env` y vuelve a correr el script de migración para actualizar los URLs en Supabase:
```bash
R2_PUBLIC_URL=https://img.yafui.guru node --env-file=.env migrate-images-r2.mjs
```

### Para los correos

En Resend → Domains → Add domain. Agrega los 3 registros DNS (SPF, DKIM). Luego:
```bash
supabase secrets set FROM_ADDRESS=hola@yafui.guru
```

---

## Variables de entorno

| Variable | Dónde se usa | Dónde se obtiene |
|---|---|---|
| `SUPABASE_URL` | `album-mexico.html` (hardcodeado) | Supabase → Settings → API |
| `SUPABASE_ANON_KEY` | `album-mexico.html` (hardcodeado) | Supabase → Settings → API |
| `SUPABASE_SERVICE_KEY` | Scripts de seed/migración | Supabase → Settings → API |
| `RESEND_API_KEY` | Supabase Edge Function (secret) | Resend → API Keys |
| `REDIRECT_URL` | Supabase Edge Function (secret) | Tu URL de Cloudflare Pages |
| `FROM_ADDRESS` | Supabase Edge Function (secret) | Tu correo verificado en Resend |
| `R2_ACCESS_KEY_ID` | Script migración (local) | Cloudflare R2 → API Tokens |
| `R2_SECRET_ACCESS_KEY` | Script migración (local) | Cloudflare R2 → API Tokens |
| `R2_ACCOUNT_ID` | Script migración (local) | URL del dashboard de Cloudflare |
| `R2_BUCKET` | Script migración (local) | Nombre del bucket que creaste |
| `R2_PUBLIC_URL` | Script migración (local) | Endpoint público del bucket R2 |

---

## Estructura del proyecto

```
album_cdmx/
├── album-mexico.html      ← Toda la app (Vue CDN, CSS, JS en un archivo)
├── escapadas-index.json   ← Fuente de datos original (~310 destinos)
├── supabase-schema.sql    ← Schema completo (idempotente, corre en SQL Editor)
├── seed-places.mjs        ← Carga los destinos del JSON a Supabase
├── migrate-images-r2.mjs  ← Migra imágenes de WordPress a Cloudflare R2
├── SETUP.md               ← Setup inicial paso a paso
├── README.md              ← Este archivo
└── supabase/
    └── functions/
        └── send-magic-link/
            └── index.ts   ← Edge Function (Deno)
```

### Schema de la base de datos

```
states          → 32 estados con región, coords, imagen
places          → ~310 destinos (vinculados a state)
profiles        → usuario (handle único auto-generado, avatar seed)
user_place_states → (user_id, place_id) → 'wanted' | 'visited' | 'loved'

Vista:   place_stats      → conteos wanted/visited/loved + trending_24h
Función: match_with_user  → "N lugares en común con @amigo"
```

---

## Escalado (cuando el free tier se quede corto)

| Umbral | Qué actualizar | Costo |
|---|---|---|
| > 50K usuarios activos/mes | Supabase Pro | $25/mes |
| > 3K correos/mes | Resend Starter | $20/mes |
| > 10 GB imágenes | R2 adicional | $0.015/GB/mes |
| Imágenes en WebP optimizado | Cloudflare Images | $5/mes (hasta 100K) |

Para el primer año de operación normal, el costo total esperado es **$0**.
