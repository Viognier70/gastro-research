import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// ─────────────────────────────────────────────────────────────────────────────
// relevance-check: bedömer befintliga artiklar (med abstract) för gastronomi-
// relevans och sätter irrelevant + relevance_checked.
//
// TRESTEGSLOGIK (per artikel):
//   0 keyword-träffar  → irrelevant = true   (gratis, ingen Haiku)
//   1 keyword-träff     → Haiku avgör ja/nej  (kontextbedömning)
//   ≥2 keyword-träffar  → irrelevant = false  (gratis, stark signal)
//
// DRY_RUN = true  → bedöm + logga, men skriv INGET till databasen.
// DRY_RUN = false → skriv irrelevant + relevance_checked på riktigt.
// ─────────────────────────────────────────────────────────────────────────────

const DRY_RUN = false         // ← skarpt läge: skriver irrelevant + relevance_checked
const BATCH_SIZE = 400         // artiklar per körning — majoriteten avgörs gratis (0kw/≥2kw)
const MAX_HAIKU_PER_RUN = 90   // tak på Haiku-anrop/körning så vi ej slår i tidsgränsen

const SB_URL = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SERVICE_ROLE_KEY') || ''
const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') || ''

const supabase = createClient(SB_URL, SB_SERVICE_KEY)

// Keyword-grupper (varje grupp som matchar = 1 träff). Samma som torrläges-SQL.
const KW_GROUPS: RegExp[] = [
  /sensor/i,
  /flavou?r/i,
  /aroma|odou?r|olfact/i,
  /taste|tasting|gustator|palate/i,
  /texture|mouthfeel/i,
  /culinary|gastronom|cuisine|chef/i,
  /wine|sommelier|beverage|brewing/i,
  /dining|restaurant|hospitality|foodservice|menu|servicescape/i,
  /food preference|food choice|appetite|satiety|palatab|hedonic/i,
  /ferment|microbio|food safety|probiotic|shelf life|preservation/i,
  /crossmodal|multisensory/i,
]

function countKeywordHits(text: string): number {
  let n = 0
  for (const re of KW_GROUPS) if (re.test(text)) n++
  return n
}

// Haiku-bedömning för den osäkra mellangruppen (1 träff).
// Returnerar true om relevant, false om inte, null vid fel (då hoppar vi över).
async function haikuIsRelevant(title: string, abstract: string): Promise<boolean | null> {
  const prompt = `You are a relevance classifier for a gastronomy research database.

The database covers food and drink as human SENSORY, CULTURAL and SERVICE experience: taste, flavour, aroma, sensory science, culinary arts, wine and beverages, dining, hospitality, food service, food preference and choice, AND food safety / food microbiology / fermentation (relevant to food professionals). It ALSO covers technology and AI applied to food as a subject: recipe analysis and generation, food/dish recognition, flavour-pairing algorithms, menu analysis, and computational/data-driven study of taste, recipes or dining.

It does NOT cover: food merely as a biological/chemical/agricultural object (pesticides, plant genetics, crop yield, animal feed, pure food-processing engineering with no link to taste/recipe/menu/experience), clinical nutrition focused on disease treatment, or papers where food is only incidental to an unrelated topic (e.g. neuroscience, economics, general chemistry).

Title: "${title.slice(0, 200)}"
Abstract: "${abstract.slice(0, 700)}"

Is this paper relevant to the gastronomy database as defined above? Answer with ONLY one word: "yes" or "no".`

  try {
    const resp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': ANTHROPIC_KEY,
        'anthropic-version': '2023-06-01'
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 5,
        messages: [{ role: 'user', content: prompt }]
      })
    })
    if (!resp.ok) {
      const errBody = await resp.text()
      console.log(`Haiku HTTP ${resp.status}: ${errBody.slice(0, 300)}`)
      return null
    }
    const d = await resp.json()
    const ans = (d.content?.[0]?.text || '').toLowerCase().trim()
    if (ans.startsWith('yes')) return true
    if (ans.startsWith('no')) return false
    console.log(`Haiku oväntat svar: "${ans}"`)
    return null
  } catch (e: any) {
    console.log('Haiku error:', e.message)
    return null
  }
}

Deno.serve(async (req) => {
  const body = await req.json().catch(() => ({}))
  const batchSize = body.batch_size || BATCH_SIZE
  const dryRun = body.dry_run !== undefined ? body.dry_run : DRY_RUN

  // Hämta obedömda artiklar med tillräckligt långt abstract för att kunna bedömas.
  // Filtret kräver minst 100 tecken i abstract (100 '_' i like-mönstret) direkt i
  // databasen — så korta/abstract-lösa artiklar hämtas aldrig och funktionen fastnar
  // inte på dem. De lämnas orörda (relevance_checked=false) och bedöms automatiskt
  // när backfill-abstracts fyllt deras abstract.
  const MIN_ABSTRACT = '_'.repeat(100)
  const { data: articles, error } = await supabase
    .from('articles')
    .select('id, title, abstract, journal, insight')
    .eq('relevance_checked', false)
    .like('abstract', `%${MIN_ABSTRACT}%`)
    .limit(batchSize)

  if (error) {
    return new Response(JSON.stringify({ ok: false, error: error.message }),
      { headers: { 'Content-Type': 'application/json' } })
  }
  if (!articles?.length) {
    return new Response(JSON.stringify({ ok: true, message: 'Inga obedömda artiklar med abstract kvar', processed: 0 }),
      { headers: { 'Content-Type': 'application/json' } })
  }

  let relevant = 0, irrelevant = 0, haikuCalls = 0, skipped = 0, deferred = 0
  const examples: any[] = []

  for (const a of articles) {
    const abstract = (a.abstract || '').trim()
    if (abstract.length < 100) { skipped++; continue }  // säkerhetsnät; filtreras redan i select

    const text = `${a.title} ${abstract}`
    const hits = countKeywordHits(text)

    let isRelevant: boolean
    let method: string

    if (hits === 0) {
      isRelevant = false
      method = '0kw'
    } else {
      // hits >= 1 → Haiku avgör. Auto-relevant-grenen (hits >= 2 utan
      // Haiku) togs bort 2026-07-09 — de 11 keyword-regexerna är för
      // breda för att bära ett auto-godkännande. Två slumpträffar på
      // /sensor/, /aroma/, /microbio/, /preservation/ räckte för att
      // släppa igenom insekticid-artiklar, kinesiska aktieindex, tak-
      // tegel-antikvariat och chimpansers bobyggande utan att prompten
      // fick titta. Prompten är rimligt formulerad — låt den svara.
      if (haikuCalls >= MAX_HAIKU_PER_RUN) { deferred++; continue }
      haikuCalls++
      const verdict = await haikuIsRelevant(a.title, abstract)
      if (verdict === null) { skipped++; continue }  // fel → lämna obedömd, försök igen senare
      isRelevant = verdict
      method = 'haiku'
    }

    if (isRelevant) relevant++; else irrelevant++

    // Spara exempel för granskning (de första 40)
    if (examples.length < 40) {
      examples.push({ method, hits, beslut: isRelevant ? 'RELEVANT' : 'irrelevant', journal: a.journal, title: a.title.slice(0, 90) })
    }

    if (!dryRun) {
      await supabase.from('articles')
        .update({ irrelevant: !isRelevant, relevance_checked: true })
        .eq('id', a.id)
    }

    // Logga bara Haiku-beslut (0kw/≥2kw är för många för loggen)
    if (method === 'haiku') {
      console.log(`[haiku] ${isRelevant ? 'RELEVANT' : 'irrelevant'}: ${a.title.slice(0,70)} [${a.journal || '-'}]`)
    }
  }

  console.log(`Klar: ${articles.length} hämtade, ${relevant} relevanta, ${irrelevant} irrelevanta, ${haikuCalls} haiku-anrop, ${deferred} uppskjutna, ${skipped} hoppade`)

  return new Response(JSON.stringify({
    ok: true,
    dry_run: dryRun,
    processed: articles.length,
    relevant,
    irrelevant,
    haiku_calls: haikuCalls,
    deferred,
    skipped,
    examples
  }, null, 2), { headers: { 'Content-Type': 'application/json' } })
})
