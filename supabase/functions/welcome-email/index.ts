import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SB_URL = Deno.env.get('SUPABASE_URL')
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
const BREVO_KEY = Deno.env.get('BREVO_API_KEY')

const SENDER = { name: 'Gusto Science', email: 'noreply@gusto.science' }
const APP_URL = 'https://gusto.science'
const UNSUB_MAILTO =
  'mailto:anders@crichton-fock.com?subject=Unsubscribe%20Gusto%20Science'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
  })

// role → one short phrase describing what they'll find. Anders authored
// these in Swedish; kept as-is so the mapping stays canonical. Rendered
// inline in an otherwise-English body — swap to English if the mix
// reads badly in production.
const ROLE_FOCUS: Record<string, string> = {
  sommelier:            'sensorik & pairing-forskning',
  chef:                 'tillämpad tillagnings- & fermenteringsforskning',
  gastronomy:           'matkultur & presentation',
  creator:              'matkultur & presentation',
  gastronomy_culture:   'matkultur & presentation',
  fb_manager:           'gästbeteende & menystrategi',
  hospitality_mgmt:     'gästbeteende & menystrategi',
  food_researcher:      'metodik & undervisningsunderlag',
  educator_researcher:  'metodik & undervisningsunderlag',
  sensory_pro:          'sensorik & pairing-forskning',
  culinary_pro:         'tillämpad tillagnings- & fermenteringsforskning'
}
const DEFAULT_FOCUS = 'research for food & drink professionals'

const isValidEmail = (v: unknown): v is string =>
  typeof v === 'string' &&
  /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v) &&
  v.length <= 254

function buildHtml(email: string, role: string | null): string {
  const focus = (role && ROLE_FOCUS[role]) || DEFAULT_FOCUS
  return `<!doctype html>
<html>
<body style="margin:0;padding:0;background:#F5EDE3;font-family:'Helvetica Neue',Arial,sans-serif;color:#2A2A2A">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F5EDE3;padding:32px 12px">
    <tr><td align="center">
      <table role="presentation" width="560" cellpadding="0" cellspacing="0" style="background:#FFFFFF;border:0.5px solid #C8C0B0;border-radius:8px;padding:32px 36px">
        <tr><td style="font-size:11px;font-weight:700;letter-spacing:.16em;text-transform:uppercase;color:#C9A84C;padding-bottom:6px">Gusto Science</td></tr>
        <tr><td style="font-size:22px;font-weight:500;color:#1A1A1A;font-family:Georgia,serif;padding-bottom:12px">Welcome</td></tr>
        <tr><td style="font-size:14px;line-height:1.7;color:#3A3A3A;padding-bottom:14px">
          Your trial is set up. Your feed is tuned for <em>${focus}</em> — drawn from the 5,000+ studies we've analysed through the TRIAD model.
        </td></tr>
        <tr><td style="font-size:14px;line-height:1.8;color:#3A3A3A;padding-bottom:20px">
          Three things to try first:
          <ul style="margin:8px 0 0 20px;padding:0">
            <li style="margin-bottom:6px">Open any article — see the ε · τ · φ read tailored to your profession.</li>
            <li style="margin-bottom:6px">Ask the research in plain language with semantic search.</li>
            <li>Save what matters, filterable by lens, in your library.</li>
          </ul>
        </td></tr>
        <tr><td style="padding:8px 0 24px">
          <a href="${APP_URL}" style="display:inline-block;background:#1A1A1A;color:#FFFFFF;text-decoration:none;padding:12px 24px;border-radius:24px;font-size:13px;font-weight:600;letter-spacing:.03em">Start exploring →</a>
        </td></tr>
        <tr><td style="border-top:0.5px solid #E6E0D2;padding-top:16px;font-size:11px;line-height:1.6;color:#8A8478">
          You received this email because ${escapeHtml(email)} signed up for a Gusto Science trial.
          If you did not sign up, or want to stop receiving emails, <a href="${UNSUB_MAILTO}" style="color:#8A8478;text-decoration:underline">let us know</a>.
        </td></tr>
      </table>
    </td></tr>
  </table>
</body>
</html>`
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

interface Incoming {
  email?: unknown
  role?: unknown
  record?: { email?: unknown; role?: unknown }
}

function extractPayload(body: Incoming): { email: string | null; role: string | null } {
  // Database Webhook shape wraps the row under `record`; direct POST is flat.
  const rec = body.record && typeof body.record === 'object' ? body.record : null
  const rawEmail = rec?.email ?? body.email
  const rawRole = rec?.role ?? body.role
  const email = isValidEmail(rawEmail) ? String(rawEmail).trim().toLowerCase() : null
  const role = typeof rawRole === 'string' && rawRole.length > 0 ? rawRole : null
  return { email, role }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  if (!BREVO_KEY) {
    console.error('welcome-email: BREVO_API_KEY not set')
    return json({ error: 'brevo_key_missing' }, 500)
  }

  let body: Incoming = {}
  try { body = await req.json() } catch (_) { return json({ error: 'invalid_json' }, 400) }

  const { email, role } = extractPayload(body)
  if (!email) return json({ error: 'invalid_email' }, 400)

  const supabase = createClient(SB_URL!, SB_KEY!)

  // Find the signup row so we can (a) key idempotency on welcome_sent_at,
  // (b) refuse to email addresses that never signed up (prevents anyone
  // with the fn URL from spraying welcome mails). If the same email has
  // multiple rows, use the most recent one.
  const { data: rows, error: fetchErr } = await supabase
    .from('trial_signups')
    .select('id, email, role, welcome_sent_at')
    .eq('email', email)
    .order('created_at', { ascending: false })
    .limit(1)

  if (fetchErr) {
    console.error('welcome-email: trial_signups lookup failed', fetchErr)
    return json({ error: 'lookup_failed' }, 500)
  }
  const row = Array.isArray(rows) ? rows[0] : null
  if (!row) return json({ error: 'signup_not_found' }, 404)

  if (row.welcome_sent_at) {
    return json({ skipped: true, reason: 'already_sent' })
  }

  const effectiveRole = role ?? row.role ?? null
  const html = buildHtml(email, effectiveRole)

  const brevoResp = await fetch('https://api.brevo.com/v3/smtp/email', {
    method: 'POST',
    headers: {
      'api-key': BREVO_KEY,
      'Content-Type': 'application/json',
      Accept: 'application/json'
    },
    body: JSON.stringify({
      sender: SENDER,
      to: [{ email }],
      subject: 'Welcome to Gusto Science — research for your profession',
      htmlContent: html,
      headers: { 'List-Unsubscribe': `<${UNSUB_MAILTO}>` }
    })
  })

  if (!brevoResp.ok) {
    const errText = await brevoResp.text().catch(() => '')
    console.error('welcome-email: Brevo send failed', brevoResp.status, errText)
    // 502 tells the Database Webhook to retry.
    return json({ error: 'brevo_send_failed', status: brevoResp.status }, 502)
  }

  const { error: updErr } = await supabase
    .from('trial_signups')
    .update({ welcome_sent_at: new Date().toISOString() })
    .eq('id', row.id)

  if (updErr) {
    // Email was sent, but we couldn't mark it — logging so Anders sees any
    // duplicates that result. Still return 200 so the webhook doesn't retry
    // and cause a second send.
    console.error('welcome-email: sent but update failed', updErr)
  }

  return json({ sent: true, email })
})
