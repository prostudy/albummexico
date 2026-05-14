// seed-places.mjs
//
// Lee tu escapadas-index.json y hace upsert de los ~250 destinos a Supabase.
// Se puede correr muchas veces: usa UNIQUE (state_slug, slug) para evitar duplicados.
//
// Uso:
//   1. npm install @supabase/supabase-js
//   2. Crea .env con:
//        SUPABASE_URL=https://xxxx.supabase.co
//        SUPABASE_SERVICE_KEY=eyJhbGc...     <- la "service_role" key, NO la anon
//   3. node --env-file=.env seed-places.mjs ./escapadas-index.json

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'
import ws from 'ws'

const url = process.env.SUPABASE_URL
const key = process.env.SUPABASE_SERVICE_KEY    // service_role, salta RLS
if (!url || !key) {
  console.error('Faltan SUPABASE_URL o SUPABASE_SERVICE_KEY en el ambiente.')
  process.exit(1)
}

const inputPath = process.argv[2]
if (!inputPath) {
  console.error('Uso: node seed-places.mjs ruta/al/escapadas-index.json')
  process.exit(1)
}

const supabase = createClient(url, key, {
  auth: { persistSession: false },
  realtime: { transport: ws },
})

// ── Helpers ──────────────────────────────────────────────────────────
const upgradeImage = (u) => {
  if (!u) return null
  return u.replace(/-\d+x\d+(\.(?:jpg|jpeg|png|webp|gif))$/i, '$1')
}

const inferType = (item) => {
  const n = (item.nombre || '').toLowerCase()
  const slug = (item.estado_slug || '').toLowerCase()
  if (slug === 'ciudad-de-mexico') return 'neighborhood'
  if (item.es_un_pueblo_magico) return 'pueblo_magico'
  if (/cancún|tulum|holbox|isla mujeres|playa del carmen|mahahual|akumal|huatulco|puerto escondido|zihuatanejo|sayulita|mazatlán|manzanillo|cozumel/.test(n)) return 'beach'
  if (/ciudad de|guadalajara|monterrey|tijuana|mexicali|hermosillo|mérida|chihuahua|morelia|toluca|pachuca|cuernavaca|querétaro|culiacán|saltillo|tampico|chetumal/.test(n)) return 'city'
  if (/biosfera|sierra|cataviña/.test(n)) return 'nature'
  return 'destination'
}

const slugFromLink = (link) => {
  try {
    const path = new URL(link).pathname.replace(/\/$/, '')
    const parts = path.split('/').filter(Boolean)
    return parts[parts.length - 1] || null
  } catch { return null }
}

const num = (v) => {
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}

// ── Main ─────────────────────────────────────────────────────────────
const raw = JSON.parse(readFileSync(inputPath, 'utf8'))
const destinos = raw.filter(it => it.tipo === 'Destino')
console.log(`Encontrados ${destinos.length} destinos en el JSON`)

// Necesitamos el mapping estado_slug → state_id (que ya está sembrado en la DB)
const { data: states, error: stErr } = await supabase
  .from('states').select('id, slug')
if (stErr) { console.error(stErr); process.exit(1) }
const stateBySlug = Object.fromEntries(states.map(s => [s.slug, s.id]))
console.log(`Estados en DB: ${states.length}`)

const rows = []
for (const d of destinos) {
  const slug = slugFromLink(d.link)
  const stateSlug = (d.estado_slug || '').toLowerCase()
  const stateId = stateBySlug[stateSlug]
  if (!stateId || !slug) {
    console.warn(`  skip: ${d.nombre} (state=${stateSlug}, slug=${slug})`)
    continue
  }
  rows.push({
    id: d.id,
    state_id: stateId,
    state_slug: stateSlug,
    slug,
    name: d.nombre,
    link: d.link,
    image_url: upgradeImage(d.image),
    is_pueblo_magico: !!d.es_un_pueblo_magico,
    place_type: inferType(d),
    lat: num(d.lat),
    lng: num(d.lng),
  })
}

// Upsert en lotes de 100
const CHUNK = 100
let inserted = 0
for (let i = 0; i < rows.length; i += CHUNK) {
  const chunk = rows.slice(i, i + CHUNK)
  const { error } = await supabase
    .from('places')
    .upsert(chunk, { onConflict: 'state_slug,slug' })
  if (error) {
    console.error(`Lote ${i}-${i+chunk.length}: ${error.message}`)
    process.exit(1)
  }
  inserted += chunk.length
  console.log(`  ${inserted}/${rows.length} subidos`)
}

console.log(`\nListo. ${inserted} destinos cargados.`)
console.log(`Pueblos Mágicos: ${rows.filter(r => r.is_pueblo_magico).length}`)
console.log('\nVerifica en Supabase: Table Editor → places')
