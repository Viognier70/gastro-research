import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import Stripe from 'https://esm.sh/stripe@14'

const SB_URL = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SERVICE_ROLE_KEY') || ''
const STRIPE_SECRET = Deno.env.get('stripe_secret_key') || ''
const STRIPE_WEBHOOK_SECRET = Deno.env.get('stripe_webhook_secret') || ''

const supabase = createClient(SB_URL, SB_SERVICE_KEY)
const stripe = new Stripe(STRIPE_SECRET, { apiVersion: '2024-04-10' })

Deno.serve(async (req) => {
  const signature = req.headers.get('stripe-signature')
  const body = await req.text()

  let event: Stripe.Event
  try {
    event = await stripe.webhooks.constructEventAsync(body, signature!, STRIPE_WEBHOOK_SECRET)
  } catch (e: any) {
    console.log('Webhook error:', e.message)
    return new Response(JSON.stringify({ error: e.message }), { status: 400 })
  }

  console.log('Webhook event:', event.type)

  if (event.type === 'checkout.session.completed') {
    const session = event.data.object as Stripe.Checkout.Session
    const userId = session.metadata?.user_id || null
    const email = session.customer_email
      || (session.customer_details as any)?.email
      || null

    console.log('userId:', userId, 'email:', email)

    if (!userId) {
      // Guest checkout path removed 2026-07-06. LAGER 2 (stripe-checkout
      // fn + frontend startCheckout) guarantees a signed-in caller before
      // a Stripe session is ever created — reaching this branch means
      // someone bypassed our checkout. DO NOT create a profile with a
      // random UUID here; that is exactly the id-drift bug backfilled
      // 2026-07-05 (profiles.id ≠ auth.users.id → isPro poll + RPC gate
      // both fail for the paying customer).
      console.log(
        `checkout without user_id — cannot link to account, email: ${email}, customer: ${session.customer}`
      )
    } else if (!email) {
      console.log(`checkout without email for user_id ${userId} — cannot record profile`)
    } else {
      // Signed-in path — upsert by id so profiles.id keeps matching auth.users.id.
      const { error } = await supabase.from('profiles').upsert({
        id: userId,
        email: email,
        is_pro: true,
        pro_since: new Date().toISOString(),
        stripe_customer_id: session.customer as string,
        stripe_subscription_id: session.subscription as string
      }, { onConflict: 'id' })
      if (error) console.log('Upsert error:', error.message)
      else console.log(`User ${userId} upgraded to Pro`)
    }
  }

  if (event.type === 'customer.subscription.deleted') {
    const sub = event.data.object as Stripe.Subscription
    const userId = sub.metadata?.user_id
    const customerId = sub.customer as string

    if (userId) {
      const { error } = await supabase.from('profiles')
        .update({ is_pro: false, pro_since: null })
        .eq('id', userId)
      if (error) console.log('Downgrade error:', error.message)
      else console.log(`User ${userId} downgraded from Pro`)
    } else if (customerId) {
      const { error } = await supabase.from('profiles')
        .update({ is_pro: false, pro_since: null })
        .eq('stripe_customer_id', customerId)
      if (error) console.log('Downgrade by customer error:', error.message)
      else console.log(`Customer ${customerId} downgraded from Pro`)
    }
  }

  return new Response(JSON.stringify({ received: true }), {
    headers: { 'Content-Type': 'application/json' }
  })
})