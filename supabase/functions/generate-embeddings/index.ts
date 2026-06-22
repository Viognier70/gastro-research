import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const OPENAI_KEY = Deno.env.get('OPENAI_API_KEY')
const SB_URL = Deno.env.get('SUPABASE_URL')
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')

Deno.serve(async () => {
  const supabase = createClient(SB_URL!, SB_KEY!)

  const { data: articles, error } = await supabase
    .from('articles')
    .select('id, title, core_claim, topic, episteme_sensory_pro, episteme_sommelier, episteme_chef')
    .not('episteme_sensory_pro', 'is', null)
    .is('embedding', null)
    .limit(50)

  if (error || !articles?.length) {
    return new Response(JSON.stringify({ ok: true, processed: 0 }), { headers: { 'Content-Type': 'application/json' } })
  }

  let processed = 0
  for (const article of articles) {
    try {
      const text = [
        article.title,
        article.core_claim,
        article.topic,
        article.episteme_sensory_pro,
        article.episteme_sommelier,
        article.episteme_chef
      ].filter(Boolean).join(' ').slice(0, 8000)

      const res = await fetch('https://api.openai.com/v1/embeddings', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${OPENAI_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ model: 'text-embedding-3-small', input: text })
      })

      const data = await res.json()
      const embedding = data.data?.[0]?.embedding
      if (!embedding) continue

      await supabase.from('articles').update({ embedding }).eq('id', article.id)
      processed++
    } catch(e) { console.error(e) }
  }

  return new Response(JSON.stringify({ ok: true, processed }), {
    headers: { 'Content-Type': 'application/json' }
  })
})
