import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const OPENAI_KEY = Deno.env.get('OPENAI_API_KEY')
const SB_URL = Deno.env.get('SUPABASE_URL')
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')

const FREE_LIMIT = 3

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

// Uniform envelope so the frontend never guesses the shape.
const envelope = (results: unknown[], remaining: number | null, limit: boolean) =>
  json({ results, remaining, limit })

async function identifyCaller(
  req: Request,
  supabase: ReturnType<typeof createClient>,
  body: { anonId?: unknown }
): Promise<{ identity: string; isAuthed: boolean; isPro: boolean }> {
  const authHeader = req.headers.get('Authorization') || ''
  const token = authHeader.replace(/^Bearer\s+/i, '').trim()

  if (token) {
    try {
      const { data: userRes, error } = await supabase.auth.getUser(token)
      const user = userRes?.user
      if (!error && user?.id) {
        const { data: profile } = await supabase
          .from('profiles')
          .select('is_pro')
          .eq('id', user.id)
          .maybeSingle()
        return {
          identity: user.id,
          isAuthed: true,
          isPro: profile?.is_pro === true
        }
      }
    } catch (_) {
      // token was the anon key, or an expired user JWT — fall through to anon path
    }
  }

  const anonId =
    typeof body.anonId === 'string' && body.anonId.length > 0
      ? body.anonId
      : 'anon-unknown'
  return { identity: anonId, isAuthed: false, isPro: false }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  let body: { query?: string; anonId?: string; limit?: number; role?: string } = {}
  try {
    body = await req.json()
  } catch (_) {
    return envelope([], null, false)
  }

  const query = typeof body.query === 'string' ? body.query.trim() : ''
  const limit = typeof body.limit === 'number' && body.limit > 0 ? body.limit : 5
  if (!query) return envelope([], null, false)

  const supabase = createClient(SB_URL!, SB_KEY!)

  const caller = await identifyCaller(req, supabase, body)

  // Rate-limit gate. Pro skips entirely; free callers upsert-and-count.
  let remaining: number | null = null
  if (!caller.isPro) {
    const { data: countData, error: countErr } = await supabase.rpc(
      'record_search_usage',
      { p_identity: caller.identity, p_is_authed: caller.isAuthed }
    )
    if (countErr) {
      console.error('record_search_usage failed:', countErr)
      // Fail open on infrastructure errors — better UX than blocking a paying
      // free user. If this fires repeatedly it will show up in logs.
    } else {
      const count = typeof countData === 'number' ? countData : Number(countData) || 0
      if (count > FREE_LIMIT) {
        return envelope([], 0, true)
      }
      remaining = Math.max(0, FREE_LIMIT - count)
    }
  }

  // Embed the query.
  const embRes = await fetch('https://api.openai.com/v1/embeddings', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${OPENAI_KEY}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ model: 'text-embedding-3-small', input: query })
  })
  const embData = await embRes.json()
  const embedding = embData.data?.[0]?.embedding
  if (!embedding) return envelope([], remaining, false)

  // pgvector similarity search.
  const { data, error } = await supabase.rpc('match_articles', {
    query_embedding: embedding,
    match_threshold: 0.3,
    match_count: limit
  })
  if (error) console.error('match_articles failed:', error)

  return envelope(Array.isArray(data) ? data : [], remaining, false)
})
