import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SB_URL = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SERVICE_ROLE_KEY') || ''
const SB_ANON = Deno.env.get('SUPABASE_ANON_KEY') || ''
const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') || ''
const supabase = createClient(SB_URL, SB_SERVICE_KEY, { auth: { persistSession: false } })

// Hard timeout: leave 20s buffer before Supabase kills us
const HARD_TIMEOUT_MS = 100000

const ROLES = [
  {role_key:'sensory_pro', role_label:'Sommelier'},
  {role_key:'culinary_pro', role_label:'Chef'},
  {role_key:'gastronomy_culture', role_label:'Gastronomy'},
  {role_key:'hospitality_mgmt', role_label:'F&B Manager'},
  {role_key:'educator_researcher', role_label:'Food Researcher & Educator'}
]

async function claimBatch(n: number) {
  try {
    const r = await fetch(`${SB_URL}/rest/v1/rpc/claim_pipeline_batch`, {
      method: 'POST',
      headers: {'Content-Type':'application/json','Authorization':`Bearer ${SB_ANON}`,'apikey':SB_ANON},
      body: JSON.stringify({ batch_size: n })
    })
    if(!r.ok) { console.log('claimBatch failed:', r.status); return [] }
    const data = await r.json()
    return Array.isArray(data) ? data : []
  } catch(e) { console.log('claimBatch error:', e.message); return [] }
}

async function runSci(article: any) {
  try {
    const roleList = ROLES.map(r => `"${r.role_key}":"${r.role_label}"`).join(',')
    const prompt = `Analyze for Gusto Science (culinary/hospitality platform).
Title: "${(article.title||'').slice(0,200)}"
Abstract: "${(article.abstract||'').slice(0,400)}"
Journal: "${article.journal||''}"
Score relevance 0-10. BE STRICT: only high if professional can directly apply in daily work.
8-10: directly addresses core tasks. 5-7: clear indirect application. 1-4: marginal. 0: irrelevant.
Roles: {${roleList}}
Return ONLY JSON: {"role_scores":{"sensory_pro":0,"culinary_pro":0,"gastronomy_culture":0,"hospitality_mgmt":0,"educator_researcher":0},"keywords":["k1","k2"],"core_claim":"one precise factual finding","headline_en":"max 8 words no punctuation","study_type":"experimental|observational|review|meta-analysis|qualitative"}`

    const resp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {'Content-Type':'application/json','x-api-key':ANTHROPIC_KEY,'anthropic-version':'2023-06-01'},
      body: JSON.stringify({model:'claude-haiku-4-5', max_tokens:500, messages:[{role:'user',content:prompt}]})
    })
    if(!resp.ok) { console.log('Haiku error:', resp.status); return null }
    const d = await resp.json()
    let t = (d.content?.[0]?.text||'{}').trim()
    t = t.replace(/^```json\s*/,'').replace(/^```\s*/,'').replace(/```[\s\S]*$/,'').trim()
    return JSON.parse(t)
  } catch(e) { console.log('runSci error:', e.message); return null }
}

async function runTriad(article: any) {
  try {
    const all = ['sensory_pro','culinary_pro','gastronomy_culture','hospitality_mgmt','educator_researcher']
    const fields = all.map(rk=>`"relevance_${rk}":5,"episteme_${rk}":"60-80w 3rd person analytical","techne_${rk}":"60-80w 2nd person instructional","phronesis_${rk}":"60-80w 2nd person present vivid"`).join(',')
    const prompt = `TRIAD: EPISTEME=universal truth 3rd person. TECHNE=craft skill 2nd person instructional. PHRONESIS=situated judgement 2nd person present.
Roles: sensory_pro=Sommelier/sensory scientist, culinary_pro=Chef/fermentation, gastronomy_culture=Food anthropologist/stylist, hospitality_mgmt=F&B manager/hotelier, educator_researcher=Researcher/culinary educator
Title: "${(article.title||'').slice(0,150)}"
Finding: "${(article.insight||article.abstract||'').slice(0,300)}"
Return ONLY JSON: {"imrad_introduction":"...","imrad_methods":"...","imrad_results":"...","imrad_discussion":"...","knowledge_explanation":"...",${fields}}`

    const resp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {'Content-Type':'application/json','x-api-key':ANTHROPIC_KEY,'anthropic-version':'2023-06-01'},
      body: JSON.stringify({model:'claude-sonnet-4-5', max_tokens:4000, messages:[{role:'user',content:prompt}]})
    })
    if(!resp.ok) { console.log('Sonnet error:', resp.status); return null }
    const d = await resp.json()
    let txt = (d.content?.[0]?.text||'{}').replace(/```json|```/g,'').trim()
    try { return JSON.parse(txt) } catch {
      // Try to recover truncated JSON
      const i = txt.lastIndexOf('}')
      if(i > 0) try { return JSON.parse(txt.slice(0,i+1)) } catch { return null }
      return null
    }
  } catch(e) { console.log('runTriad error:', e.message); return null }
}

async function save(article: any, sci: any, triad: any) {
  try {
    const u: any = {}
    if(sci) {
      const rs = sci.role_scores||{}
      u.relevance_sci_sensory_pro = rs.sensory_pro??0
      u.relevance_sci_culinary_pro = rs.culinary_pro??0
      u.relevance_sci_gastronomy_culture = rs.gastronomy_culture??0
      u.relevance_sci_hospitality_mgmt = rs.hospitality_mgmt??0
      u.relevance_sci_educator_researcher = rs.educator_researcher??0
      u.keywords = sci.keywords||[]
      u.core_claim = sci.core_claim||null
      u.study_type = sci.study_type||null
      if(sci.headline_en) u.headline_en = sci.headline_en
    }
    if(triad) {
      u.imrad_introduction = triad.imrad_introduction||null
      u.imrad_methods = triad.imrad_methods||null
      u.imrad_results = triad.imrad_results||null
      u.imrad_discussion = triad.imrad_discussion||null
      u.knowledge_explanation = triad.knowledge_explanation||null
      u.knowledge_type = 'mixed'
      for(const role of ['sensory_pro','culinary_pro','gastronomy_culture','hospitality_mgmt','educator_researcher']) {
        u[`episteme_${role}`] = triad[`episteme_${role}`]||null
        u[`techne_${role}`] = triad[`techne_${role}`]||null
        u[`phronesis_${role}`] = triad[`phronesis_${role}`]||null
      }
    }
    const {error} = await supabase.from('articles').update(u).eq('id', article.id)
    if(error) console.log('Save error:', article.id.slice(0,8), error.message)
    return !error
  } catch(e) { console.log('save exception:', e.message); return false }
}

async function releaseStuck() {
  // Release articles stuck in 'processing' for >10 min
  const tenMinAgo = new Date(Date.now() - 10*60*1000).toISOString()
  await supabase.from('processing_queue')
    .update({status:'pending', updated_at: new Date().toISOString()})
    .eq('status','processing')
    .lt('updated_at', tenMinAgo)
}

Deno.serve(async (_req) => {
  const startTime = Date.now()
  let processed = 0, errors = 0

  // Release stuck items first
  await releaseStuck()

  // Skip if too many already processing
  const {count:procCount} = await supabase.from('processing_queue')
    .select('*',{count:'exact',head:true}).eq('status','processing')
  if((procCount||0) > 20) {
    return new Response(JSON.stringify({ok:true,skipped:true,reason:'already_running',processing:procCount}),
      {headers:{'Content-Type':'application/json'}})
  }

  const batch = await claimBatch(5)
  if(!batch.length) {
    const {count:remaining} = await supabase.from('processing_queue')
      .select('id',{count:'exact',head:true}).eq('status','pending')
    return new Response(JSON.stringify({ok:true,processed:0,errors:0,remaining:remaining||0,elapsed:Date.now()-startTime}),
      {headers:{'Content-Type':'application/json'}})
  }

  for(const item of batch) {
    // Safety check: leave enough time for next article
    if(Date.now()-startTime > HARD_TIMEOUT_MS) {
      console.log('Approaching timeout, stopping early')
      // Release unprocessed items back to pending
      await supabase.from('processing_queue')
        .update({status:'pending', updated_at: new Date().toISOString()})
        .eq('id', item.id)
      break
    }

    const article = item.article
    if(!article) {
      await supabase.from('processing_queue').update({status:'pending',updated_at:new Date().toISOString()}).eq('id',item.id)
      continue
    }

    // Skip articles without enough content
    if(!article.title || article.title.length < 10) {
      await supabase.from('processing_queue').update({status:'done',sci_done:true,triad_done:true,updated_at:new Date().toISOString()}).eq('id',item.id)
      processed++
      continue
    }

    console.log('Processing:', item.article_id.slice(0,8), article.title?.slice(0,50))

    try {
      // Step 1: Sci analysis (Haiku) — only if not done
      const sci = (!item.sci_done && article.abstract && article.abstract.length > 50)
        ? await runSci(article) : null

      // Step 2: Determine max relevance
      const sciScores = sci?.role_scores || {}
      const dbScores = {
        sensory_pro: article.relevance_sci_sensory_pro||0,
        culinary_pro: article.relevance_sci_culinary_pro||0,
        gastronomy_culture: article.relevance_sci_gastronomy_culture||0,
        hospitality_mgmt: article.relevance_sci_hospitality_mgmt||0,
        educator_researcher: article.relevance_sci_educator_researcher||0
      }
      const effectiveScores = Object.keys(sciScores).length ? sciScores : dbScores
      // Om sci redan är klar och inga scores finns — anta relevans 5 (annars skippas TRIAD felaktigt)
      const maxRelevance = item.sci_done && !Object.keys(sciScores).length && Math.max(...Object.values(dbScores).map((v:any) => Number(v)||0)) === 0
        ? 5
        : Math.max(...Object.values(effectiveScores).map((v:any) => Number(v)||0))

      // Step 3: TRIAD (Sonnet) — only if relevant and not done
      const hasAbstract = article.abstract && article.abstract !== '[unavailable]' && article.abstract.length > 50
      const shouldTriad = !item.triad_done && hasAbstract && maxRelevance >= 5
      const triad = shouldTriad ? await runTriad(article) : null

      if(!shouldTriad && !item.triad_done) {
        console.log('Skipping TRIAD — relevance:', maxRelevance)
      }

      // Step 4: Save
      await save(article, sci, triad)

      // Step 5: Update queue status
      const sciDone = item.sci_done || !!sci
      const triadDone = item.triad_done || !!triad || !shouldTriad
      await supabase.from('processing_queue').update({
        status: sciDone && triadDone ? 'done' : 'pending',
        sci_done: sciDone,
        triad_done: triadDone,
        attempts: (item.attempts||0) + 1,
        updated_at: new Date().toISOString()
      }).eq('id', item.id)

      processed++
    } catch(e: any) {
      console.log('Error:', item.article_id.slice(0,8), e.message)
      await supabase.from('processing_queue').update({
        status: 'pending',
        attempts: (item.attempts||0) + 1,
        last_error: e.message?.slice(0,200),
        updated_at: new Date().toISOString()
      }).eq('id', item.id)
      errors++
    }

    await new Promise(r => setTimeout(r, 200))
  }

  const {count:remaining} = await supabase.from('processing_queue')
    .select('id',{count:'exact',head:true}).eq('status','pending')
  console.log(`Done: ${processed} processed, ${errors} errors, ${remaining} remaining`)

  return new Response(JSON.stringify({
    ok: true, processed, errors,
    remaining: remaining||0,
    elapsed: Date.now()-startTime
  }), {headers:{'Content-Type':'application/json'}})
})
