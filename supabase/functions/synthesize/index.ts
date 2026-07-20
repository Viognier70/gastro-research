import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const ANTHROPIC_KEY  = Deno.env.get('ANTHROPIC_API_KEY') || ''
const SB_URL         = Deno.env.get('SUPABASE_URL') || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
const supabase = createClient(SB_URL, SB_SERVICE_KEY, { auth: { persistSession: false } })
const CORS = {'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Content-Type':'application/json'}

// Role är science-namn (sensory_pro, culinary_pro, gastronomy_culture,
// hospitality_mgmt, educator_researcher). articles.episteme_<science> och
// articles.relevance_sci_<science> har 9 200+ rader vardera — pipeline
// skriver dit. Legacy chip-kolumner (episteme_sommelier m.fl.) har 100–500
// rader kvar sedan roll-migrationen och är inte längre sanningen. Vi läser
// science-namn direkt, ingen mappning behövs.
// Whitelist för injection-guard mot .select()-interpolation OCH för att
// enforca science-namnrymden. Efter denna check är dbRole 100% science-namn
// och namn-konventionen (dbRole for SQL, aldrig 'role') gör att
// scripts/lint-role-columns.sh inte flaggar interpolationen.
const VALID_ROLES = new Set(['sensory_pro','culinary_pro','gastronomy_culture','hospitality_mgmt','educator_researcher'])

Deno.serve(async (req) => {
  if(req.method==='OPTIONS') return new Response('ok',{headers:CORS})
  const body = await req.json().catch(()=>({}))
  const { topic } = body
  const dbRole = VALID_ROLES.has(String(body.role || '')) ? String(body.role) : ''
  if(!dbRole||!topic) return new Response(JSON.stringify({error:'role and topic required',invalid_role:!VALID_ROLES.has(String(body.role||''))}),{status:400,headers:CORS})

  const { data: articles, error: readErr } = await supabase
    .from('articles')
    .select(`id,title,core_claim,episteme_${dbRole}`)
    .eq('topic', topic)
    .not(`episteme_${dbRole}`, 'is', null)
    .order(`relevance_sci_${dbRole}`, { ascending: false, nullsFirst: false })
    .limit(10)

  if(readErr) {
    return new Response(JSON.stringify({error:'read_failed',db_error:readErr.message,code:readErr.code}),{status:500,headers:CORS})
  }
  if(!Array.isArray(articles) || articles.length < 3) {
    return new Response(JSON.stringify({error:'insufficient_articles',count:articles?.length||0,role:dbRole,topic}),{headers:CORS})
  }

  const summaries = articles.map((a:any,i:number)=>`[${i+1}] "${a.title}": ${(a.core_claim||'').slice(0,120)}`).join('\n')
  const prompt = `Write ONE synthesis JSON for a ${dbRole} about "${topic.replace(/_/g,' ')}".\nArticles:\n${summaries.slice(0,700)}\nReturn ONLY JSON:\n{"title":"5-8 words","convergence":"Research consistently shows X.","synthesis":"For you as a ${dbRole}, X.","evidence_strength":"strong|moderate|emerging"}`

  const resp = await fetch('https://api.anthropic.com/v1/messages',{
    method:'POST',
    headers:{'Content-Type':'application/json','x-api-key':ANTHROPIC_KEY,'anthropic-version':'2023-06-01'},
    body:JSON.stringify({model:'claude-haiku-4-5',max_tokens:600,messages:[{role:'user',content:prompt}]})
  })
  const d = await resp.json()
  const txt = d.content?.[0]?.text||''

  let parsed:any = null
  try{ parsed = JSON.parse(txt.replace(/^```json\s*/,'').replace(/```\s*$/,'')) }catch(e){
    const m=txt.match(/\{[^{}]+\}/s); if(m) try{parsed=JSON.parse(m[0])}catch(e2){}
  }
  if(!parsed||!parsed.title) return new Response(JSON.stringify({error:'parse_failed',txt:txt.slice(0,200)}),{headers:CORS})

  const synth = parsed.synthesis||parsed.convergence||''
  const { error: saveErr } = await supabase
    .from('research_syntheses')
    .upsert({
      role: dbRole, topic,
      title: parsed.title||'',
      synthesis: synth,
      synthesis_text: synth,
      convergence: parsed.convergence||'',
      evidence_strength: parsed.evidence_strength||'moderate',
      article_count: articles.length,
      topics: [topic],
      professions: [dbRole],
      updated_at: new Date().toISOString()
    }, { onConflict: 'role,topic' })

  if(saveErr) {
    return new Response(JSON.stringify({error:'save_failed',db_error:saveErr.message,code:saveErr.code}),{status:500,headers:CORS})
  }
  return new Response(JSON.stringify({ok:true,synthesis:parsed,role:dbRole,topic,article_count:articles.length}),{headers:CORS})
})
