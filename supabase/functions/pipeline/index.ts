import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { buildTriadPrompt, parseLabeledProse, validateTriad, fieldsToDbUpdate } from '../_shared/labeled-triad.ts'

const SB_URL = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SERVICE_ROLE_KEY') || ''
const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') || ''
const supabase = createClient(SB_URL, SB_SERVICE_KEY, { auth: { persistSession: false } })

// Hard timeout: leave 20s buffer before Supabase kills us
const HARD_TIMEOUT_MS = 100000

// TRIAD kostnadsbroms. Default på (bakåtkompatibelt). Sätts till '0' via
// supabase secrets när Sonnet-räknaren ska frysas — pipeline fortsätter
// köra runSci (Haiku, billigt) men hoppar över runTriad (Sonnet, 99% av
// Anthropic-räkningen). Artiklar som är TRIAD-berättigade men körs i
// gate-off-läge markeras triad_done=true och lämnar kön; att slå på
// TRIAD igen senare berör alltså bara NYA artiklar. Redan-hoppade
// måste re-enqueueas separat.
const TRIAD_ENABLED = Deno.env.get('TRIAD_ENABLED') !== '0'

const ROLES = [
  {role_key:'sensory_pro', role_label:'Sommelier'},
  {role_key:'culinary_pro', role_label:'Chef'},
  {role_key:'gastronomy_culture', role_label:'Gastronomy'},
  {role_key:'hospitality_mgmt', role_label:'F&B Manager'},
  {role_key:'educator_researcher', role_label:'Food Researcher & Educator'}
]

async function claimBatch(n: number) {
  const { data, error } = await supabase.rpc('claim_pipeline_batch', { batch_size: n })
  if (error) {
    console.log('claimBatch failed:', error.message, error.code)
    return []
  }
  return Array.isArray(data) ? data : []
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
      body: JSON.stringify({model:'claude-haiku-4-5-20251001', max_tokens:500, messages:[{role:'user',content:prompt}]})
    })
    if(!resp.ok) { const err = await resp.json().catch(()=>{}); console.log('Haiku error:', resp.status, JSON.stringify(err)); return null }
    const d = await resp.json()
    let t = (d.content?.[0]?.text||'{}').trim()
    t = t.replace(/^```json\s*/,'').replace(/^```\s*/,'').replace(/```[\s\S]*$/,'').trim()
    return JSON.parse(t)
  } catch(e) { console.log('runSci error:', e.message); return null }
}

// Prompt-format, parser, validering och DB-mapping ligger i
// ../_shared/labeled-triad.ts. Returnerar ParseResult (som save() konsumerar)
// eller null vid Sonnet-fel/exception.
async function runTriad(article: any): Promise<ReturnType<typeof parseLabeledProse> | null> {
  try {
    const prompt = buildTriadPrompt(article)
    const resp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {'Content-Type':'application/json','x-api-key':ANTHROPIC_KEY,'anthropic-version':'2023-06-01'},
      body: JSON.stringify({model:'claude-sonnet-4-6', max_tokens:4000, messages:[{role:'user',content:prompt}]})
    })
    if(!resp.ok) { console.log('Sonnet error:', resp.status); return null }
    const d = await resp.json()
    const rawText = (d.content?.[0]?.text || '').trim()
    return parseLabeledProse(rawText)
  } catch(e: any) { console.log('runTriad error:', e.message); return null }
}

// triad-parametern är nu ParseResult (från labeled-triad-parsern) istället
// för raw JSON. Om validateTriad() returnerar non-null skrivs INGA TRIAD-
// fält — sci-delen skrivs oberoende (relevance_sci_*, keywords, headline).
async function save(article: any, sci: any, triad: ReturnType<typeof parseLabeledProse> | null) {
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
      const parseError = validateTriad(triad)
      if(parseError) {
        console.log(`TRIAD invalid ${article.id.slice(0,8)}: ${parseError}`,
          { missing: triad.missing.length, too_short: triad.too_short.length, extra: triad.extra.length })
      } else {
        Object.assign(u, fieldsToDbUpdate(triad.fields))
      }
    }
    const {error} = await supabase.from('articles').update(u).eq('id', article.id)
    if(error) console.log('Save error:', article.id.slice(0,8), error.message)
    return !error
  } catch(e: any) { console.log('save exception:', e.message); return false }
}

async function releaseStuck() {
  // Release articles stuck in 'processing' for >10 min
  const tenMinAgo = new Date(Date.now() - 10*60*1000).toISOString()
  await supabase.from('processing_queue')
    .update({status:'pending', updated_at: new Date().toISOString()})
    .eq('status','processing')
    .lt('updated_at', tenMinAgo)
}

// Max attempts innan raden markeras permanent failed. En rad utan
// väg framåt är samma lögn som en obedömbar artikel kvar i kön.
const MAX_ATTEMPTS = 5

Deno.serve(async (_req) => {
  const startTime = Date.now()
  let processed = 0, errors = 0, sciCalls = 0, triadCalls = 0
  let skipped = 0, permanentlyFailed = 0

  // Release stuck items first
  await releaseStuck()

  // Skip if too many already processing
  const {count:procCount} = await supabase.from('processing_queue')
    .select('*',{count:'exact',head:true}).eq('status','processing')
  if((procCount||0) > 20) {
    return new Response(JSON.stringify({ok:true,skipped:true,reason:'already_running',processing:procCount}),
      {headers:{'Content-Type':'application/json'}})
  }

  const batch = await claimBatch(20)
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

    // Skip articles without enough content. Tidigare markerades de som
    // status='done' med sci_done=true/triad_done=true — samma lögn som
    // "obedömbar artikel räknas relevant". Nu status='skipped' med skäl
    // så de syns i last_error och kan re-processas om title fylls i.
    if(!article.title || article.title.length < 10) {
      await supabase.from('processing_queue').update({
        status: 'skipped',
        last_error: 'title too short (< 10 chars) — cannot analyze',
        updated_at: new Date().toISOString()
      }).eq('id', item.id)
      skipped++
      continue
    }

    console.log('Processing:', item.article_id.slice(0,8), article.title?.slice(0,50))

    try {
      // Step 1: Sci analysis (Haiku) — only if not done
      let sci: any = null
      if (!item.sci_done && article.abstract && article.abstract.length > 50) {
        sciCalls++
        sci = await runSci(article)
      }

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

      // Step 3: TRIAD (Sonnet) — only if relevant and not done. TRIAD_ENABLED
      // är kostnadsgate: när '0' skippas Sonnet-anropet men artikeln markeras
      // ändå triad_done nedan så kön inte fastnar. Re-enable påverkar bara
      // nya artiklar.
      const hasAbstract = article.abstract && article.abstract !== '[unavailable]' && article.abstract.length > 50
      const shouldTriad = TRIAD_ENABLED && !item.triad_done && hasAbstract && maxRelevance >= 5
      let triad: any = null
      if (shouldTriad) {
        triadCalls++
        triad = await runTriad(article)
      }

      if(!shouldTriad && !item.triad_done) {
        console.log('Skipping TRIAD — relevance:', maxRelevance)
      }

      // Step 4: Save — FÅNGA returvärdet. sci_done/triad_done sätts ENDAST
      // när save verkligen lyckades. Tidigare version satte flaggorna
      // baserat på !!sci (Haiku-svar), oberoende av save-utfall → skapade
      // ~9 462 spöken där kön säger "klart" men articles-tabellen är NULL.
      const saved = await save(article, sci, triad)
      const newAttempts = (item.attempts || 0) + 1

      if (!saved) {
        // Save misslyckades — flaggorna behåller sina gamla värden. attempts
        // ökas. Om vi når MAX_ATTEMPTS: status='failed' med last_error så
        // raden lämnar kön permanent istället för att ligga kvar som pending
        // för alltid.
        const failed = newAttempts >= MAX_ATTEMPTS
        await supabase.from('processing_queue').update({
          status: failed ? 'failed' : 'pending',
          attempts: newAttempts,
          last_error: `save failed on attempt ${newAttempts} of ${MAX_ATTEMPTS}`,
          updated_at: new Date().toISOString()
        }).eq('id', item.id)
        if (failed) permanentlyFailed++
        errors++
        continue
      }

      // Save lyckades → flaggorna reflekterar vad som faktiskt skrevs.
      // triad räknas som DONE bara om parsningen validerades. Om triad har
      // missing/too_short-fält skrevs ingenting, och artikeln ska plockas
      // igen nästa batch för nytt Sonnet-försök.
      const sciDone = item.sci_done || !!sci
      const triadOk = !!(triad && !validateTriad(triad))
      const triadDone = item.triad_done || triadOk || !shouldTriad

      await supabase.from('processing_queue').update({
        status: sciDone && triadDone ? 'done' : 'pending',
        sci_done: sciDone,
        triad_done: triadDone,
        attempts: newAttempts,
        last_error: null,   // rensa ev. tidigare fel när save lyckas
        updated_at: new Date().toISOString()
      }).eq('id', item.id)

      processed++
    } catch(e: any) {
      console.log('Error:', item.article_id.slice(0,8), e.message)
      const newAttempts = (item.attempts||0) + 1
      const failed = newAttempts >= MAX_ATTEMPTS
      await supabase.from('processing_queue').update({
        status: failed ? 'failed' : 'pending',
        attempts: newAttempts,
        last_error: e.message?.slice(0,200) || 'unknown exception',
        updated_at: new Date().toISOString()
      }).eq('id', item.id)
      if (failed) permanentlyFailed++
      errors++
    }

    await new Promise(r => setTimeout(r, 200))
  }

  const {count:remaining} = await supabase.from('processing_queue')
    .select('id',{count:'exact',head:true}).eq('status','pending')
  console.log(`Done: ${processed} processed, ${errors} errors, ${remaining} remaining`)

  return new Response(JSON.stringify({
    ok: true,
    processed,                            // save() lyckades, sci_done/triad_done reflekterar sanning
    errors,                               // save() misslyckades eller kastade
    skipped,                              // title < 10 chars, status='skipped'
    permanently_failed: permanentlyFailed, // attempts nådde MAX_ATTEMPTS, status='failed'
    sci_calls: sciCalls,
    triad_calls: triadCalls,
    triad_enabled: TRIAD_ENABLED,
    batch_size: 20,
    remaining: remaining||0,
    elapsed: Date.now()-startTime
  }), {headers:{'Content-Type':'application/json'}})
})
