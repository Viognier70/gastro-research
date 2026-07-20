import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SB_URL = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
const STRIPE_SECRET = Deno.env.get('stripe_secret_key') || ''

const PRICES: Record<string, string> = {
  monthly: 'price_1TVcAb01M2w13V3nTNPZZ9VF',
  annual: 'price_1TVcBM01M2w13V3n75yXbGd0'
}

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    console.log('stripe-checkout called, secret loaded:', STRIPE_SECRET ? 'yes' : 'NO')
    
    const body = await req.json()
    const { plan, user_id, email, success_url, cancel_url } = body
    console.log('Plan:', plan, 'Email:', email)

    // Product is unusable without an account (isPro is read via auth.uid()),
    // so an anonymous purchase would immediately hit the id-drift bug —
    // profiles row keyed on a random UUID vs. auth.users.id. Refuse before
    // creating a Stripe session so nothing hits the webhook without a way
    // to link the payment to a user.
    if (!user_id) {
      return new Response(JSON.stringify({ error: 'authentication required for checkout' }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    const priceId = PRICES[plan || 'monthly']
    if (!priceId) {
      return new Response(JSON.stringify({ error: 'Invalid plan' }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    if (!STRIPE_SECRET) {
      return new Response(JSON.stringify({ error: 'Stripe not configured' }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    // Call Stripe API directly (no SDK needed)
    const params = new URLSearchParams({
      'payment_method_types[]': 'card',
      'line_items[0][price]': priceId,
      'line_items[0][quantity]': '1',
      'mode': 'subscription',
      'success_url': success_url || 'https://gusto.science?pro=true',
      'cancel_url': cancel_url || 'https://gusto.science',
      'allow_promotion_codes': 'true',
    })

    if (email) params.set('customer_email', email)
    // user_id required above — always attach both metadata targets so the
    // webhook can key on session.metadata.user_id AND on any subscription
    // event carrying subscription.metadata.user_id.
    params.set('metadata[user_id]', user_id)
    params.set('subscription_data[metadata][user_id]', user_id)

    const stripeResp = await fetch('https://api.stripe.com/v1/checkout/sessions', {
      method: 'POST',
      headers: {
        'Authorization': `Basic ${btoa(STRIPE_SECRET + ':')}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: params.toString()
    })

    const session = await stripeResp.json()
    console.log('Stripe response status:', stripeResp.status)

    if (!stripeResp.ok) {
      console.log('Stripe error:', JSON.stringify(session))
      return new Response(JSON.stringify({ error: session.error?.message || 'Stripe error' }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    return new Response(JSON.stringify({ url: session.url, session_id: session.id }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    })

  } catch (e: any) {
    console.log('Error:', e.message)
    return new Response(JSON.stringify({ error: e.message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    })
  }
})