// stripe-portal — skapar Stripe billing portal-session för inloggad Pro-user.
// ORDER 129, 2026-08-22.
//
// SÄKERHET: identitet verifieras via JWT (sb.auth.getUser), INTE via body-fält.
// Skillnad mot stripe-checkout (som tar user_id i body): en portal-session
// ger full self-service på ett abonnemang (avsluta, byta betalningsmetod).
// Body-passed user_id skulle öppna för att en angripare öppnar portalen för
// annans customer_id.
//
// FRONTEND-KONTRAKT: knappen renderas bara när is_pro=true OCH
// stripe_customer_id finns (openSettings i index.html). Denna fn dubbelkollar
// samma villkor server-side som defensivt fångnät.
//
// return_url: hårdkodad https://gusto.science/ — user landar på hem efter
// Manage/Cancel i Stripe-portalen. Ingen hash-router-jack för att åter-öppna
// modalen; hem är rätt ankare efter en betalningsflödes-retur.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SB_URL         = Deno.env.get('SUPABASE_URL')               || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')  || ''
const STRIPE_SECRET  = Deno.env.get('stripe_secret_key')          || ''

const RETURN_URL = 'https://gusto.science/'

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, 'Content-Type': 'application/json' } })

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })

  if (!STRIPE_SECRET) {
    return json({ error: 'stripe_not_configured' }, 500)
  }

  const supabase = createClient(SB_URL, SB_SERVICE_KEY, { auth: { persistSession: false } })

  // JWT-verifierad identitet — kräver Bearer-header.
  const authHeader = req.headers.get('Authorization') || ''
  const jwt = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : ''
  if (!jwt) return json({ error: 'signin_required' }, 401)

  const { data: userData, error: authErr } = await supabase.auth.getUser(jwt)
  if (authErr || !userData?.user) return json({ error: 'signin_required' }, 401)
  const userId = userData.user.id

  // Server-side dubbel-guard mot frontend-kontraktet.
  const { data: profile, error: profErr } = await supabase.from('profiles')
    .select('is_pro, stripe_customer_id')
    .eq('id', userId).maybeSingle()
  if (profErr) return json({ error: 'profile_read_failed' }, 500)
  if (!profile?.is_pro)               return json({ error: 'not_pro' }, 403)
  if (!profile?.stripe_customer_id)   return json({ error: 'no_customer' }, 404)

  // Direktanrop mot Stripe REST — samma stil som stripe-checkout (ingen SDK).
  const params = new URLSearchParams({
    customer:   profile.stripe_customer_id,
    return_url: RETURN_URL,
  })

  const stripeResp = await fetch('https://api.stripe.com/v1/billing_portal/sessions', {
    method: 'POST',
    headers: {
      'Authorization': `Basic ${btoa(STRIPE_SECRET + ':')}`,
      'Content-Type':  'application/x-www-form-urlencoded',
    },
    body: params.toString(),
  })

  const session = await stripeResp.json()
  if (!stripeResp.ok) {
    console.log('Stripe portal error:', JSON.stringify(session))
    return json({ error: session.error?.message || 'stripe_error' }, 400)
  }

  return json({ url: session.url })
})
