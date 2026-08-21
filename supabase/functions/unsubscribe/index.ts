// unsubscribe — publik avanmälnings-endpoint för veckobrevet.
//
// URL:    GET /functions/v1/unsubscribe?t=<digest_token>
// Undo:   GET /functions/v1/unsubscribe?t=<digest_token>&undo=1
//
// Ett klick = server-side flip av profiles.digest_enabled via
// set_digest_enabled(token, enabled)-RPC. Returnerar en fristående
// HTML-sida — ingen JS krävs, funkar även när user's mail-klient
// öppnar länken i tunn browser.
//
// Deploy: supabase functions deploy unsubscribe --no-verify-jwt
// (måste vara callable från email-link utan JWT.)
//
// Design-noter (ORDER 121, 2026-08-21):
//   1. Server-renderad HTML valt över statisk sida + AJAX — undviker
//      extra round-trip och funkar även med JS av. Mail-link-scanners
//      som prefetchar HTML triggar unsub direkt, men ångra-länken är
//      omedelbart synlig på svaret så use kan reverta.
//   2. Neutralt svar oavsett token-utfall — samma sida visas för
//      okänd som för giltig token. Avslöjar aldrig om en token
//      existerar. Malformed UUID hoppar RPC helt (samma neutral sida).
//   3. Ångra funkar via samma endpoint med &undo=1. Ingen inloggning,
//      samma one-click-mönster.
//   4. RPC set_digest_enabled är SECURITY DEFINER — anon får inte
//      skriva mot profiles direkt (migration 20260821130000).

const SB_URL  = Deno.env.get('SUPABASE_URL')       || ''
const SB_ANON = Deno.env.get('SUPABASE_ANON_KEY')  || ''

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

async function callRpc(token: string, enabled: boolean): Promise<number> {
  try {
    const r = await fetch(`${SB_URL}/rest/v1/rpc/set_digest_enabled`, {
      method: 'POST',
      headers: {
        'apikey':        SB_ANON,
        'Authorization': `Bearer ${SB_ANON}`,
        'Content-Type':  'application/json',
      },
      body: JSON.stringify({ p_token: token, p_enabled: enabled }),
    })
    if (!r.ok) {
      console.error(`[unsubscribe] RPC ${r.status}: ${(await r.text()).slice(0, 200)}`)
      return 0
    }
    const data = await r.json().catch(() => 0)
    return typeof data === 'number' ? data : 0
  } catch (e) {
    console.error('[unsubscribe] RPC threw:', e)
    return 0
  }
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!))
}

function page(opts: { title: string; body: string; actionUrl?: string; actionLabel?: string }): string {
  const { title, body, actionUrl, actionLabel } = opts
  const actionHtml = actionUrl && actionLabel
    ? `<a href="${escapeHtml(actionUrl)}" style="display:inline-block;margin-top:24px;font-size:13px;font-weight:600;color:#fff;background:#C9A84C;padding:10px 22px;border-radius:22px;text-decoration:none;font-family:'Outfit',system-ui,sans-serif">${escapeHtml(actionLabel)}</a>`
    : ''
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>${escapeHtml(title)} · Gusto Science</title>
<style>
  body{margin:0;padding:0;background:#F7F4ED;font-family:'Outfit',system-ui,-apple-system,sans-serif;color:#0C0B09;min-height:100vh;display:flex;align-items:center;justify-content:center}
  .card{max-width:460px;margin:24px auto;padding:36px 28px;background:#fff;border:1px solid #E8E0D0;border-radius:12px;text-align:center;box-shadow:0 1px 3px rgba(12,11,9,0.04)}
  .brand{font-family:Georgia,serif;font-size:22px;color:#0C0B09;margin:0 0 6px}
  .brand-eyebrow{font-size:10px;font-weight:700;letter-spacing:.14em;text-transform:uppercase;color:#C9A84C;margin:0 0 24px}
  h1{font-family:Georgia,serif;font-size:22px;font-weight:400;color:#0C0B09;margin:0 0 14px;line-height:1.35}
  p{font-size:14px;color:#5C5649;line-height:1.65;margin:0 0 10px}
  .foot{margin-top:28px;padding-top:20px;border-top:1px solid #E8E0D0;font-size:11px;color:#9C9484}
  a{color:#836428}
</style>
</head>
<body>
  <div class="card">
    <p class="brand-eyebrow">Gusto Science</p>
    <h1>${escapeHtml(title)}</h1>
    ${body}
    ${actionHtml}
    <div class="foot">
      Weekly research digest · Gusto Science<br>
      Dr Anders Crichton-Fock
    </div>
  </div>
</body>
</html>`
}

function unsubPage(token: string): string {
  // Undo-URL: samma endpoint, samma token, med &undo=1
  const undoUrl = `?t=${encodeURIComponent(token)}&undo=1`
  return page({
    title: 'You\'ve been unsubscribed',
    body: `<p>If this email address was subscribed to the Gusto Science weekly digest, we've stopped sending it.</p>
           <p style="margin-top:14px">Was this a mistake?</p>`,
    actionUrl: undoUrl,
    actionLabel: 'Undo — resubscribe',
  })
}

function undonePage(token: string): string {
  // Reverse: klick på "Undo unsub" leder tillbaka till plain unsub-URL
  const unsubUrl = `?t=${encodeURIComponent(token)}`
  return page({
    title: 'Welcome back',
    body: `<p>If this email address is registered, you'll receive the next weekly digest.</p>
           <p style="margin-top:14px">Changed your mind again?</p>`,
    actionUrl: unsubUrl,
    actionLabel: 'Unsubscribe',
  })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  if (req.method !== 'GET') {
    return new Response('Method Not Allowed', {
      status: 405,
      headers: { ...CORS, 'Content-Type': 'text/plain' },
    })
  }

  const url    = new URL(req.url)
  const token  = url.searchParams.get('t')   || ''
  const isUndo = url.searchParams.get('undo') === '1'
  const enabled = isUndo   // true = resubscribe, false = unsubscribe

  // UUID sanity — malformad token hoppar RPC direkt men visar SAMMA
  // sida som en giltig-men-okänd token (neutralt utfall).
  const isValidUuid = UUID_RE.test(token)
  let rowCount = 0
  if (isValidUuid) {
    rowCount = await callRpc(token, enabled)
    // Logga token-miss för abuse-tracking. INTE synligt för användaren.
    if (rowCount === 0) console.log(`[unsubscribe] token miss (undo=${isUndo})`)
  } else if (token) {
    console.log('[unsubscribe] malformed token payload')
  }

  const html = isUndo ? undonePage(token) : unsubPage(token)

  return new Response(html, {
    status: 200,
    headers: {
      ...CORS,
      'Content-Type':  'text/html; charset=utf-8',
      // Ingen cache — svaret speglar server-state per anrop.
      'Cache-Control': 'no-store',
      // Klargör att detta är transactional-endpoint, inte trackbar länk.
      'Referrer-Policy': 'no-referrer',
    },
  })
})
