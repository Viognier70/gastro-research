import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
const SB_URL = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SERVICE_ROLE_KEY') || ''
const supabase = createClient(SB_URL, SB_SERVICE_KEY, {auth:{persistSession:false}})

Deno.serve(async (_req) => {
  const {data:articles} = await supabase.from('articles')
    .select('id,url,title,authors')
    .or('abstract.is.null,abstract.eq.')
    .like('url','%doi.org%')
    .limit(50)

  if(!articles?.length) return new Response(JSON.stringify({ok:true,processed:0}),{headers:{'Content-Type':'application/json','Access-Control-Allow-Origin':'*'}})

  let filled = 0, errors = 0
  for(const article of articles){
    try {
      const doi = article.url.replace('https://doi.org/','').replace('http://doi.org/','')
      const r = await fetch('https://api.crossref.org/works/'+encodeURIComponent(doi),{
        headers:{'User-Agent':'GustoScience/1.0 (mailto:anders@crichton-fock.com)'}
      })
      if(!r.ok){ errors++; await supabase.from('articles').update({abstract:'[unavailable]'}).eq('id',article.id); continue }
      const data = await r.json()
      const work = data.message
      const abstract = (work.abstract||'').replace(/<[^>]+>/g,'').trim()
      const authors = !article.authors ? (work.author||[]).map((a:any)=>[(a.family||''),(a.given||'')].filter(Boolean).join(' ')).join(', ') : null
      const update: any = {abstract: abstract.length>50 ? abstract : '[unavailable]'}
      if(authors) update.authors = authors
      await supabase.from('articles').update(update).eq('id',article.id)
      if(abstract.length>50) filled++
      await new Promise(r=>setTimeout(r,120))
    } catch(e){ errors++ }
  }

  return new Response(JSON.stringify({ok:true,processed:articles.length,filled,errors}),{headers:{'Content-Type':'application/json','Access-Control-Allow-Origin':'*'}})
})
