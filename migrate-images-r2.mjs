/**
 * Migra imágenes de mexicodesconocido.com.mx → Cloudflare R2
 * y actualiza los image_url en Supabase.
 *
 * Uso:  node --env-file=.env migrate-images-r2.mjs
 *
 * Variables requeridas en .env:
 *   SUPABASE_URL, SUPABASE_SERVICE_KEY
 *   R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ACCOUNT_ID
 *   R2_BUCKET, R2_PUBLIC_URL
 */

import { createClient } from '@supabase/supabase-js'
import { S3Client, PutObjectCommand, HeadObjectCommand } from '@aws-sdk/client-s3'

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
)

const r2 = new S3Client({
  region: 'auto',
  endpoint: `https://${process.env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
  credentials: {
    accessKeyId: process.env.R2_ACCESS_KEY_ID,
    secretAccessKey: process.env.R2_SECRET_ACCESS_KEY,
  },
})

const BUCKET      = process.env.R2_BUCKET
const PUBLIC_URL  = process.env.R2_PUBLIC_URL.replace(/\/$/, '')

// ── helpers ──────────────────────────────────────────────────────────────────

async function existsInR2(key) {
  try {
    await r2.send(new HeadObjectCommand({ Bucket: BUCKET, Key: key }))
    return true
  } catch {
    return false
  }
}

async function downloadImage(url) {
  const res = await fetch(url, { signal: AbortSignal.timeout(15_000) })
  if (!res.ok) throw new Error(`HTTP ${res.status} → ${url}`)
  const buffer = Buffer.from(await res.arrayBuffer())
  const contentType = res.headers.get('content-type') || 'image/jpeg'
  return { buffer, contentType }
}

function keyFromUrl(prefix, url) {
  const filename = url.split('/').pop().split('?')[0]
  return `${prefix}/${filename}`
}

async function migrateRow({ table, id, originalUrl, prefix }) {
  const key = keyFromUrl(prefix, originalUrl)

  if (await existsInR2(key)) {
    const newUrl = `${PUBLIC_URL}/${key}`
    // Actualiza aunque ya esté en R2, por si cambió R2_PUBLIC_URL
    await supabase.from(table).update({ image_url: newUrl }).eq('id', id)
    return { status: 'skipped', key }
  }

  const { buffer, contentType } = await downloadImage(originalUrl)

  await r2.send(new PutObjectCommand({
    Bucket: BUCKET,
    Key: key,
    Body: buffer,
    ContentType: contentType,
    CacheControl: 'public, max-age=31536000, immutable',
  }))

  const newUrl = `${PUBLIC_URL}/${key}`
  await supabase.from(table).update({ image_url: newUrl }).eq('id', id)

  return { status: 'uploaded', key, newUrl }
}

async function migrateTable(table, prefix) {
  const { data, error } = await supabase
    .from(table)
    .select('id, image_url')
    .not('image_url', 'is', null)

  if (error) throw new Error(`Supabase error en ${table}: ${error.message}`)

  const rows = data.filter(r => r.image_url && !r.image_url.includes(PUBLIC_URL))
  console.log(`\n[${table}] ${rows.length} imágenes a procesar`)

  let uploaded = 0, skipped = 0, failed = 0

  for (const row of rows) {
    try {
      const result = await migrateRow({
        table,
        id: row.id,
        originalUrl: row.image_url,
        prefix,
      })
      if (result.status === 'uploaded') {
        console.log(`  ✓ ${result.key}  →  ${result.newUrl}`)
        uploaded++
      } else {
        console.log(`  · ${result.key}  (ya existe, URL actualizado)`)
        skipped++
      }
    } catch (err) {
      console.error(`  ✗ id=${row.id}  ${err.message}`)
      failed++
    }
  }

  return { uploaded, skipped, failed }
}

// ── main ─────────────────────────────────────────────────────────────────────

const required = [
  'SUPABASE_URL', 'SUPABASE_SERVICE_KEY',
  'R2_ACCESS_KEY_ID', 'R2_SECRET_ACCESS_KEY', 'R2_ACCOUNT_ID',
  'R2_BUCKET', 'R2_PUBLIC_URL',
]
const missing = required.filter(k => !process.env[k])
if (missing.length) {
  console.error('Faltan variables de entorno:', missing.join(', '))
  process.exit(1)
}

console.log(`Bucket: ${BUCKET}`)
console.log(`Public URL: ${PUBLIC_URL}`)

const states = await migrateTable('states', 'states')
const places = await migrateTable('places', 'places')

const total = {
  uploaded: states.uploaded + places.uploaded,
  skipped:  states.skipped  + places.skipped,
  failed:   states.failed   + places.failed,
}

console.log(`\nListo. ${total.uploaded} subidas, ${total.skipped} ya existían, ${total.failed} errores.`)
if (total.failed > 0) process.exit(1)
