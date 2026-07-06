// Newsletter signup — adds an email to the Gusto Science newsletter list in
// Brevo. Reuses the existing BREVO_API_KEY secret (same account as
// welcome-email); no new secret required.
//
// Deploy: supabase functions deploy newsletter-signup --no-verify-jwt
// (must be callable without a user JWT — anon visitors subscribe here.)

const BREVO_KEY = Deno.env.get('BREVO_API_KEY')

// Brevo list ID for "Gusto Science Newsletter". Not sensitive — safe to
// keep as a constant. Change here if the list is ever renumbered.
const NEWSLETTER_LIST_ID = 9

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

const isValidEmail = (v: unknown): v is string =>
  typeof v === 'string' &&
  /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v) &&
  v.length <= 254

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    if (!BREVO_KEY) {
      console.error('newsletter-signup: BREVO_API_KEY not set')
      return json({ error: 'brevo_key_missing' }, 500)
    }

    let body: { email?: unknown } = {}
    try { body = await req.json() } catch (_) {
      return json({ error: 'invalid_json' }, 400)
    }

    const rawEmail = typeof body.email === 'string' ? body.email.trim().toLowerCase() : ''
    if (!isValidEmail(rawEmail)) {
      return json({ error: 'invalid_email' }, 400)
    }

    // Brevo Contacts API. updateEnabled:true → an existing contact is
    // updated rather than rejected. If the contact is already in this
    // list, Brevo still returns success (204) via that path.
    const brevoResp = await fetch('https://api.brevo.com/v3/contacts', {
      method: 'POST',
      headers: {
        'api-key': BREVO_KEY,
        'Content-Type': 'application/json',
        Accept: 'application/json'
      },
      body: JSON.stringify({
        email: rawEmail,
        listIds: [NEWSLETTER_LIST_ID],
        updateEnabled: true
      })
    })

    if (brevoResp.ok) {
      // 201 Created or 204 No Content — Brevo accepted the contact.
      return json({ ok: true, subscribed: true })
    }

    // Duplicate contacts are a soft success: user is already on the list.
    // Brevo returns 400 with a "duplicate_parameter" code / message. Treat
    // this as ok so the modal shows the "Thanks" state and the user isn't
    // punished for trying twice.
    const errBody = await brevoResp.text().catch(() => '')
    if (
      brevoResp.status === 400 &&
      /duplicate|already exist|contact.*exist/i.test(errBody)
    ) {
      return json({ ok: true, subscribed: true, already: true })
    }

    console.error('newsletter-signup: Brevo failed', brevoResp.status, errBody)
    return json({ error: 'brevo_error', status: brevoResp.status }, 502)
  } catch (outerErr) {
    // Last-resort guard — never leak the exception details, never leak the key.
    console.error('newsletter-signup: unexpected', outerErr)
    return json({ error: 'internal' }, 500)
  }
})
