const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') || ''
const SB_URL = Deno.env.get('SUPABASE_URL') || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_ANON = Deno.env.get('SUPABASE_ANON_KEY') || ''
const CORS = {'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Content-Type':'application/json'}

async function dbGet(path: string) {
  const r = await fetch(`${SB_URL}/rest/v1/${path}`, {headers:{'Authorization':`Bearer ${SB_ANON}`,'apikey':SB_ANON}})
  return r.json()
}

async function dbPost(path: string, data: any) {
  const r = await fetch(`${SB_URL}/rest/v1/${path}`, {method:'POST',headers:{'Authorization':`Bearer ${SB_ANON}`,'apikey':SB_ANON,'Content-Type':'application/json','Prefer':'return=minimal'},body:JSON.stringify(data)})
  return r
}

Deno.serve(async (req) => {
  if(req.method==='OPTIONS') return new Response('ok',{headers:CORS})
  const {role, topic} = await req.json()
  if(!role||!topic) return new Response(JSON.stringify({error:'role and topic required'}),{status:400,headers:CORS})

  const col = ({'meal_creator':'creator','fb_manager':'fbmanager'} as any)[role]||role

  const articles = await dbGet(`articles?select=id,title,core_claim,episteme_${col}&topic=eq.${topic}&episteme_${col}=not.is.null&order=relevance_sci_${col}.desc.nullslast&limit=10`)
  console.log('articles:', Array.isArray(articles) ? articles.length : 'error', JSON.stringify(articles).slice(0,100))

  if(!Array.isArray(articles)||articles.length<3) return new Response(JSON.stringify({error:'insufficient_articles',count:Array.isArray(articles)?articles.length:0}),{headers:CORS})

  const summaries = articles.map((a:any,i:number)=>`[${i+1}] "${a.title}": ${(a.core_claim||'').slice(0,120)}`).join('\n')
  const prompt = `Write ONE synthesis JSON for a ${role} about "${topic.replace(/_/g,' ')}".\nArticles:\n${summaries.slice(0,700)}\nReturn ONLY JSON:\n{"title":"5-8 words","convergence":"Research consistently shows X.","synthesis":"For you as a ${role}, X.","evidence_strength":"strong|moderate|emerging"}`

  const resp = await fetch('https://api.anthropic.com/v1/messages',{method:'POST',headers:{'Content-Type':'application/json','x-api-key':ANTHROPIC_KEY,'anthropic-version':'2023-06-01'},body:JSON.stringify({model:'claude-haiku-4-5',max_tokens:600,messages:[{role:'user',content:prompt}]})})
  const d = await resp.json()
  const txt = d.content?.[0]?.text||''
  
  let parsed:any = null
  try{ parsed = JSON.parse(txt.replace(/^```json\s*/,'').replace(/```\s*$/,'')) }catch(e){
    const m=txt.match(/\{[^{}]+\}/s); if(m) try{parsed=JSON.parse(m[0])}catch(e2){}
  }
  if(!parsed||!parsed.title) return new Response(JSON.stringify({error:'parse_failed',txt:txt.slice(0,200)}),{headers:CORS})

  const synth = parsed.synthesis||parsed.convergence||''
  const saveResp = await dbPost('research_syntheses', {
    role,topic,title:parsed.title||'',synthesis:synth,synthesis_text:synth,
    convergence:parsed.convergence||'',evidence_strength:parsed.evidence_strength||'moderate',
    article_count:articles.length,topics:[topic],professions:[role]
  })
  console.log('save status:', saveResp.status, await saveResp.text())
  return new Response(JSON.stringify({ok:true,synthesis:parsed}),{headers:CORS})
})
