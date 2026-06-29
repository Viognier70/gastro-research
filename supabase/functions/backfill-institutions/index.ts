import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
const SB_URL = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SERVICE_ROLE_KEY') || ''
const supabase = createClient(SB_URL, SB_SERVICE_KEY)
const CORS = {'Access-Control-Allow-Origin':'*','Content-Type':'application/json'}
Deno.serve(async (req) => {
  if(req.method==='OPTIONS') return new Response('ok',{headers:CORS})
  const { data: articles } = await supabase.from('articles').select('id, url').eq('source', 'openalex').is('institution_coords', null).not('url', 'is', null).not('episteme_sensory_pro', 'is', null).limit(50)
  if(!articles?.length) return new Response(JSON.stringify({ok:true, processed:0, message:'No articles to backfill'}), {headers:CORS})
  let processed = 0, errors = 0
  for(const article of articles) {
    try {
      const doi = article.url?.replace(/https:\/\/doi\.org\//g, '')
      if(!doi) continue
      const r = await fetch(`https://api.openalex.org/works/doi:${encodeURIComponent(doi)}?select=authorships`)
      if(!r.ok) { errors++; continue }
      const d = await r.json()
      const authorships = d.authorships || []
      const institutions = [...new Set(authorships.flatMap((a:any) => (a.institutions||[]).map((i:any) => i.display_name)).filter(Boolean))]
      const countries = [...new Set(authorships.flatMap((a:any) => (a.institutions||[]).map((i:any) => i.country_code)).filter(Boolean))]
      // Hämta koordinater från university_rankings
      const instNames = [...new Set(authorships.flatMap((a:any) => (a.institutions||[]).map((i:any) => i.display_name).filter(Boolean)))]
      const institution_coords: any[] = []
      for(const name of instNames) {
        const { data: ranking } = await supabase.from('university_rankings').select('lat,lng,country_code').ilike('name', name).limit(1).single()
        if(ranking?.lat) {
          institution_coords.push({name, lat: ranking.lat, lng: ranking.lng, country: ranking.country_code})
        }
      }
      const country = (countries[0] as string) || ''
      const { error } = await supabase.from('articles').update({institutions, countries, institution_coords, country}).eq('id', article.id)
      if(error) { errors++; continue }
      processed++
      await new Promise(r => setTimeout(r, 120))
    } catch(e) { errors++ }
  }
  const {count} = await supabase.from('articles').select('id',{count:'exact',head:true}).eq('source','openalex').is('institution_coords',null)
  return new Response(JSON.stringify({ok:true, processed, errors, remaining:count}), {headers:CORS})
})
