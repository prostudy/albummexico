// supabase/functions/send-magic-link/index.ts
//
// Edge Function que:
//   1. Recibe un email
//   2. Pide a Supabase Auth que genere un magic link (sin enviarlo)
//   3. Envía un correo bonito con Resend con ese link
//
// Por qué no usamos el correo nativo de Supabase:
//   - Está limitado a 4/hora en el tier free
//   - El "from" siempre es noreply@supabase.io
//   - No se puede personalizar el HTML
// Con Resend tenemos 3,000/mes gratis, dominio propio (cuando lo tengas),
// HTML estilizado.
//
// Deploy:
//   supabase functions deploy send-magic-link --no-verify-jwt
//   supabase secrets set RESEND_API_KEY=re_XXX
//   supabase secrets set REDIRECT_URL=https://tu-album.com
//
// Llamarla desde el frontend:
//   await supabase.functions.invoke('send-magic-link', { body: { email } })

import { serve } from 'https://deno.land/std@0.224.0/http/server.ts'
import { createClient } from 'jsr:@supabase/supabase-js@2'

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')!
const SUPABASE_URL   = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY    = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const REDIRECT_URL   = Deno.env.get('REDIRECT_URL') || 'http://localhost:5173'
const FROM_ADDRESS   = Deno.env.get('FROM_ADDRESS') || 'onboarding@resend.dev'
const FROM_NAME      = Deno.env.get('FROM_NAME')    || 'Álbum México'

// CORS
const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',     // restringe a tu dominio en producción
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

const isValidEmail = (s: string) =>
  /^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$/i.test(s)

// ── Plantilla del correo (HTML inline) ───────────────────────────────
const emailHTML = (magicLink: string, email: string) => `
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Tu acceso al Álbum México</title>
</head>
<body style="margin:0; padding:0; background:#F4ECE0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif; color:#1A1714;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#F4ECE0; padding: 40px 20px;">
    <tr>
      <td align="center">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width: 520px; background: #FBF6EE; border-radius: 20px; padding: 40px 32px; box-shadow: 0 4px 24px rgba(26,23,20,0.08);">
          <tr>
            <td>
              <div style="font-family: Georgia, 'Times New Roman', serif; font-size: 28px; font-weight: 500; letter-spacing: -0.01em; color:#1A1714; margin: 0 0 8px;">
                Álbum <em style="color:#B23A2E;">México</em>
              </div>
              <div style="font-size: 12px; letter-spacing: 0.15em; text-transform: uppercase; color:#8A7A6E; margin-bottom: 32px;">
                tu pasaporte de viajero
              </div>

              <h1 style="font-family: Georgia, serif; font-size: 22px; font-weight: 500; line-height: 1.2; margin: 0 0 16px; color:#1A1714;">
                Tu acceso está listo
              </h1>

              <p style="font-size: 16px; line-height: 1.55; color:#4A413A; margin: 0 0 28px;">
                Solicitaste entrar al Álbum México con <strong>${email}</strong>. Da clic al botón y abrimos tu álbum.
              </p>

              <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                <tr>
                  <td style="border-radius: 999px; background:#1A1714;">
                    <a href="${magicLink}"
                       style="display: inline-block; padding: 14px 28px; color:#FBF6EE; text-decoration: none; font-weight: 600; font-size: 15px; letter-spacing: 0.02em; border-radius: 999px;">
                      Abrir mi álbum →
                    </a>
                  </td>
                </tr>
              </table>

              <p style="font-size: 13px; line-height: 1.5; color:#8A7A6E; margin: 28px 0 0;">
                El link funciona por <strong>1 hora</strong> y solo desde este correo. Si no lo solicitaste, ignora este mensaje.
              </p>

              <div style="border-top: 1px solid #DCCFB9; margin: 32px 0 16px;"></div>

              <p style="font-size: 12px; color:#8A7A6E; margin: 0; word-break: break-all;">
                Si el botón no abre, copia este link:<br>
                <span style="color:#4A413A;">${magicLink}</span>
              </p>
            </td>
          </tr>
        </table>

        <div style="font-size: 11px; color:#8A7A6E; margin-top: 24px;">
          © Álbum México — Construido para viajeros.
        </div>
      </td>
    </tr>
  </table>
</body>
</html>
`

// ── Handler ──────────────────────────────────────────────────────────
serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST')    return json({ error: 'method_not_allowed' }, 405)

  let body: { email?: string }
  try { body = await req.json() }
  catch { return json({ error: 'invalid_json' }, 400) }

  const email = (body.email || '').trim().toLowerCase()
  if (!email || !isValidEmail(email)) return json({ error: 'invalid_email' }, 400)

  // Genera el magic link sin que Supabase lo envíe
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } })
  const { data, error } = await admin.auth.admin.generateLink({
    type: 'magiclink',
    email,
    options: { redirectTo: REDIRECT_URL },
  })
  if (error) {
    console.error('generateLink error:', error)
    return json({ error: 'could_not_generate_link' }, 500)
  }

  const magicLink = data.properties?.action_link
  if (!magicLink) return json({ error: 'no_link_returned' }, 500)

  // Manda el correo con Resend
  const resendRes = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from:    `${FROM_NAME} <${FROM_ADDRESS}>`,
      to:      [email],
      subject: 'Tu acceso al Álbum México',
      html:    emailHTML(magicLink, email),
    }),
  })

  if (!resendRes.ok) {
    const errText = await resendRes.text()
    console.error('Resend error:', errText)
    return json({ error: 'resend_failed', detail: errText }, 502)
  }

  return json({ ok: true })
})
