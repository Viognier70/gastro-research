import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const OPENAI_KEY = Deno.env.get('OPENAI_API_KEY')
const SB_URL = Deno.env.get('SUPABASE_URL')
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  const { query, limit = 5 } = await req.json()
  if (!query) return new Response(JSON.stringify([]), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })

  const embRes = await fetch('https://api.openai.com/v1/embeddings', {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${OPENAI_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: 'text-embedding-3-small', input: query })
  })
  const embData = await embRes.json()
  const embedding = embData.data?.[0]?.embedding
  if (!embedding) return new Response(JSON.stringify([]), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })

  const supabase = createClient(SB_URL!, SB_KEY!)
  const { data, error } = await supabase.rpc('match_articles', {
    query_embedding: embedding,
    match_threshold: 0.3,
    match_count: limit
  })

  if (error) console.error(error)

  return new Response(JSON.stringify(data || []), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
  })
})
