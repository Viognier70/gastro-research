// ask-synth — query→syntetiserat svar för Ask-vyn (B2-revideat, 2026-07-22).
// Flöde: embed → pgvector-match → hämta TRIAD-payload → Sonnet-syntes →
// validera citations → return {answer, citations, sources, confidence}.
//
// Steg 1 av bygget: INGEN per-user-kvot än (ask_quota kommer i steg 2).
// GLOBAL daily budget (ASK_DAILY_BUDGET) via ask_budget_claim-RPC är
// däremot AKTIV — defensiv broms mot skenande kostnad även under test.
//
// Anti-hallucination på tre lager:
// 1. Prompt: "Answer ONLY from SOURCES. Cite [N] every claim. If insufficient,
//    say so — do not speculate."
// 2. Server-gate: <3 pgvector-träffar över threshold → insufficient_coverage
// 3. LLM self-report: coverage_note='insufficient' → insufficient_coverage
//
// Verifierbara citations: sources returneras med idx som matchar [N] i answer
// så frontend kan göra klickbara [1][2]-länkar till motsvarande källa-kort.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') || ''
const OPENAI_KEY    = Deno.env.get('OPENAI_API_KEY')    || ''
const SB_URL        = Deno.env.get('SUPABASE_URL')      || ''
const SB_KEY        = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
const DAILY_BUDGET  = parseInt(Deno.env.get('ASK_DAILY_BUDGET') || '100', 10)

// Roll-mappning (chip → science-namn). Speglar frontendens toDbRole så
// vi kan ta emot båda formaten från klient utan att bry oss om vilken
// nomenklatur den skickar.
const VALID_ROLES = new Set(['sensory_pro','culinary_pro','gastronomy_culture','hospitality_mgmt','educator_researcher'])
const CHIP_TO_DB: Record<string,string> = {
  sommelier: 'sensory_pro',
  chef: 'culinary_pro',
  gastronomy: 'gastronomy_culture',
  fb_manager: 'hospitality_mgmt',
  food_researcher: 'educator_researcher',
}
function toDbRole(r: string): string {
  if (VALID_ROLES.has(r)) return r
  return CHIP_TO_DB[r] || 'sensory_pro'
}
function roleLabelHuman(r: string): string {
  const map: Record<string,string> = {
    sensory_pro: 'Sommelier',
    culinary_pro: 'Chef',
    gastronomy_culture: 'Meal Creator',
    hospitality_mgmt: 'Hospitality Management',
    educator_researcher: 'Academic',
  }
  return map[r] || r
}

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, 'Content-Type': 'application/json' } })

// SYSTEM_PROMPT bakas per anrop så language-direktivet (rule 8) speglar
// användarens UI-språk. TRIAD-källorna är på engelska oavsett — bara
// answer-texten (och coverage_note-strängen) ska följa språkvalet.
//
// LANG-PARAMETERN 2026-08-02: bevaras avsiktligt trots att frontend inte
// längre skickar den. Beslut samma dag: engelska är grundspråk (TRIAD är
// på engelska, målgruppen arbetar på engelska, halvöversatt UI togs bort).
// Klienten skickar aldrig lang idag → body.lang är alltid undefined →
// buildSystemPrompt får 'en' via defaulten nedan. När/om i18n återinförs
// senare behövs bara frontendens body-fält igen; kontraktet står kvar
// server-side. RENSA INTE utan att också ta bort motsvarande server-
// fallback i buildSystemPrompt/L() nedan.
function buildSystemPrompt(lang: 'sv' | 'en'): string {
  const langLine = lang === 'sv'
    ? 'Respond in SWEDISH. All prose in "answer" must be Swedish. Do NOT translate source titles or journal names when quoting.'
    : 'Respond in ENGLISH. All prose in "answer" must be English.'
  return `You synthesize peer-reviewed research for professionals in gastronomy (chefs, sommeliers, F&B managers, meal creators, food researchers).

STRICT RULES:
1. Answer ONLY from the numbered SOURCES provided. Do not use outside knowledge or general priors.
2. Cite every substantive claim with [1], [2], etc. matching the source numbers. Every factual sentence needs a citation.
3. If the SOURCES don't cover the question, set coverage_note to "insufficient" and leave answer empty. Do not speculate, do not partially answer.
4. Address the practitioner directly (2nd person "you"). Concrete, applicable, actionable. No filler.
5. Confidence: "high" if 3+ sources converge; "medium" if 2 sources or mixed evidence; "low" if sources contradict but multiple substantively address the question. If ONLY ONE source substantively covers the question → set coverage_note to "insufficient", do NOT report "low". Better to say you don't know than fabricate specifics (numbers, protocols, parameters) with a plausible-looking citation. If SOURCES lack specific values, do not invent them.
6. Keep answer to 1-3 short paragraphs. No headings, no bullets inside the answer text.
7. If the question is off-topic (unrelated to gastronomy/food research), treat as insufficient — do not answer.
8. LANGUAGE: ${langLine} The SOURCES provided are in English (extracted from TRIAD analyses stored in that language). Do not translate them in the "answer" text itself when a source title is quoted verbatim, but express your synthesis, reasoning, and any paraphrased content in the requested language.

OUTPUT: valid JSON matching this schema exactly:
{
  "answer": "prose with inline [1][2] citations",
  "citations": [{"ref": 1, "article_id": "<uuid from source>"}, {"ref": 2, "article_id": "<uuid>"}],
  "confidence": "high" | "medium" | "low",
  "coverage_note": "" or "insufficient"
}

Return ONLY the JSON. No prose before or after. No code fences.`
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  const startedAt = Date.now()

  // Parse body
  let body: {
    query?: unknown
    role?: unknown
    top_k?: unknown
    lang?: unknown
  } = {}
  try { body = await req.json() } catch (_) {}

  const query = typeof body.query === 'string' ? body.query.trim() : ''
  const rawRole = typeof body.role === 'string' ? body.role : 'sommelier'
  const topK = Math.min(Math.max(parseInt(String(body.top_k), 10) || 6, 3), 10)
  const dbRole = toDbRole(rawRole === 'all' ? 'sommelier' : rawRole)
  const roleHuman = roleLabelHuman(dbRole)
  // UI-språk från frontend styr Sonnet-svaret + serverns error-strängar.
  // Default 'en' om klienten inte skickar värdet (bakåtkompat).
  const lang: 'sv' | 'en' = body.lang === 'sv' ? 'sv' : 'en'
  const L = (sv: string, en: string) => lang === 'sv' ? sv : en

  if (query.length < 5) return json({ status: 'error', error: 'query_too_short' }, 400)
  if (!ANTHROPIC_KEY || !OPENAI_KEY || !SB_URL || !SB_KEY) {
    return json({ status: 'error', error: 'server_misconfigured' }, 500)
  }

  const supabase = createClient(SB_URL, SB_KEY, { auth: { persistSession: false } })

  // ── PER-USER QUOTA (ORDER 112, 2026-08-20) ──────────────────────────
  // Kör FÖRE ask_budget_claim så global cap inte konsumeras för anrop
  // som ändå ska blockas. Anon kräver sign-in (Free-tier lock).
  // Samma auth-mönster som triad-on-demand (rad ~108).
  const authHeader = req.headers.get('Authorization') || ''
  const jwt = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : ''
  let userId: string | null = null
  if (jwt) {
    const { data: userData, error: authErr } = await supabase.auth.getUser(jwt)
    if (!authErr && userData?.user) userId = userData.user.id
  }
  if (!userId) {
    return json({
      status: 'signin_required',
      free_daily: 3,
      message: L(
        'Logga in för att använda Ask. Free-konton får 3 frågor per dag; Pro är obegränsat.',
        'Sign in to use Ask. Free accounts get 3 questions per day; Pro is unlimited.'
      ),
    }, 401)
  }

  // is_pro server-side. Klienten kan inte sätta detta. Samma pattern
  // som triad-on-demand (endast is_pro, inte trial_ends_at — trial ger
  // TRIAD men inte automatiskt obegränsat Ask; separat produktbeslut).
  const { data: profile } = await supabase.from('profiles')
    .select('is_pro').eq('id', userId).maybeSingle()
  const isPro = !!profile?.is_pro

  const { data: quotaRemRaw, error: quotaErr } = await supabase.rpc('ask_quota_claim', {
    p_user_id: userId, p_is_pro: isPro
  })
  if (quotaErr) {
    console.error('ask_quota_claim failed:', quotaErr)
    return json({ status: 'error', error: `quota_claim: ${quotaErr.message}` }, 500)
  }
  const quotaRem = quotaRemRaw as number
  if (quotaRem === -1) {
    return json({
      status: 'quota_exceeded',
      free_daily: 3,
      is_pro: false,
      message: L(
        'Du har använt dina 3 gratis Ask-frågor idag. Kom tillbaka imorgon, eller uppgradera till Pro för obegränsat.',
        'You\'ve used your 3 free Ask questions today. Come back tomorrow, or upgrade to Pro for unlimited.'
      ),
    }, 402)
  }
  // För Pro: quotaRem = 999999 → skickas som null till klienten (ingen
  // count-badge visas). För Free: 0-2 återstående efter denna claim.
  const quotaRemainingForClient: number | null = isPro ? null : quotaRem

  // GLOBAL DAILY BUDGET — hard cap ovanpå per-user-kvot.
  const { data: budgetRem, error: budgetErr } = await supabase.rpc('ask_budget_claim', { p_budget: DAILY_BUDGET })
  if (budgetErr) {
    console.error('ask_budget_claim failed:', budgetErr)
    return json({ status: 'error', error: `budget_claim: ${budgetErr.message}` }, 500)
  }
  if (budgetRem === -1) {
    return json({ status: 'budget_exceeded', daily_budget: DAILY_BUDGET }, 503)
  }

  // STEP 1: embed query
  const embRes = await fetch('https://api.openai.com/v1/embeddings', {
    method: 'POST',
    headers: { Authorization: `Bearer ${OPENAI_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: 'text-embedding-3-small', input: query }),
  })
  if (!embRes.ok) {
    const eBody = await embRes.text()
    console.error('embed error:', embRes.status, eBody.slice(0, 200))
    return json({ status: 'error', error: `embed: ${embRes.status}` }, 502)
  }
  const embData = await embRes.json()
  const embedding = embData.data?.[0]?.embedding
  if (!embedding) return json({ status: 'error', error: 'embed_no_vector' }, 500)

  // STEP 2: pgvector match + HYBRID GATE
  // Threshold 0.5 för att hämta bredare set; gate distingerar två godkända
  // evidens-mönster från det farliga tredje:
  //
  //   A) KONVERGENS: strong_count >= 3 (3+ träffar med similarity > 0.53).
  //      Flera semantiskt nära källor bekräftar samma domän. Sonnet får
  //      SE bara strong (konservativt — utesluter svaga peers).
  //
  //   B) SPIKE + PEERS: strong_count >= 1 AND top_sim > 0.55 AND total >= 5.
  //      Ett tydligt spike ovanför 0.55 med minst 5 nära peers i fältet.
  //      Sonnet får SE alla matches (spike ankar syntesen, peers ger domän-
  //      kontext). Prompt-regel 5 tvingar coverage_note='insufficient' om
  //      bara 1 källa SUBSTANTIVT täcker frågan — Sonnet är sista skiktet.
  //
  //   AVVISAS: "FLAT MESS" — jämnt mediocra hits utan spike, utan konvergens.
  //      Detta var Q1-surdeg-mönstret 2026-07-23: 6 träffar 0.500-0.529, alla
  //      off-topic (organkött, svamp, bryggspill, vin), Sonnet uppfann
  //      protokoll-siffror med falsk citation.
  //
  // Kalibrering (2026-07-23) baserad på 4 testfrågor:
  //   Q1 surdeg:   0 strong, top 0.529         → refuseras (varken A eller B)
  //   Q2 musik:    6 strong, top 0.653         → A (konvergens)
  //   Q3 neuro:    1 strong, top 0.557, 6 total → B (spike + peers)
  //   Q4 kvantum:  0 strong, top —             → refuseras
  // Övervaka verkliga user-queries efter lansering och justera vid behov.
  const STRONG_SIM = 0.53
  const TOP_SIM_ANCHOR = 0.55
  const MIN_PEERS = 5

  const { data: matches, error: matchErr } = await supabase.rpc('match_articles', {
    query_embedding: embedding,
    match_threshold: 0.5,
    match_count: topK,
  })
  if (matchErr) {
    console.error('match_articles failed:', matchErr)
    return json({ status: 'error', error: `match: ${matchErr.message}` }, 500)
  }
  const allMatches: any[] = Array.isArray(matches) ? matches : []
  const strongMatches = allMatches.filter((m: any) => (m.similarity || 0) > STRONG_SIM)
  const topSim = allMatches[0]?.similarity || 0
  const totalHits = allMatches.length

  const isConvergence = strongMatches.length >= 3
  const isSpikeWithPeers = strongMatches.length >= 1 && topSim > TOP_SIM_ANCHOR && totalHits >= MIN_PEERS

  if (!isConvergence && !isSpikeWithPeers) {
    return json({
      status: 'insufficient_coverage',
      message: L(
        `De hittade artiklarna räcker inte för att besvara frågan för ${roleHuman}.`,
        `The retrieved articles do not provide sufficient evidence to answer this question for ${roleHuman}.`
      ),
      reason: strongMatches.length === 0 ? 'no_strong_hits' : 'weak_evidence_pattern',
      gate: { strong_threshold: STRONG_SIM, top_sim_anchor: TOP_SIM_ANCHOR, min_peers: MIN_PEERS },
      observed: { strong_count: strongMatches.length, top_sim: topSim, total_hits: totalHits },
      hits_summary: allMatches.map((a: any) => ({ article_id: a.id, title: a.title, similarity: a.similarity })),
    })
  }

  // Konvergens → bara strong (konservativt). Spike → alla matches (spike + peers).
  const sonnetSources: any[] = isConvergence ? strongMatches : allMatches

  // STEP 3: fetch full TRIAD payload (service_role kringgår Pro-gate)
  const ids = sonnetSources.map((m: any) => m.id)
  const { data: full, error: fullErr } = await supabase
    .from('articles')
    .select(`id, title, headline_en, journal, year, core_claim, limitation, episteme_${dbRole}, techne_${dbRole}, phronesis_${dbRole}`)
    .in('id', ids)
  if (fullErr) {
    console.error('articles read failed:', fullErr)
    return json({ status: 'error', error: `articles: ${fullErr.message}` }, 500)
  }
  const byId = new Map((full || []).map((a: any) => [a.id, a]))

  // Bygg sources i pgvector-ranking-ordning (mest lika först)
  const sources = sonnetSources.map((m: any, i: number) => {
    const f: any = byId.get(m.id) || {}
    return {
      idx: i + 1,
      id: m.id,
      title: f.headline_en || m.title || '',
      journal: m.journal || '',
      year: m.year || '',
      core_claim: f.core_claim || m.core_claim || '',
      limitation: f.limitation || '',
      episteme: f[`episteme_${dbRole}`] || '',
      techne: f[`techne_${dbRole}`] || '',
      phronesis: f[`phronesis_${dbRole}`] || '',
      similarity: m.similarity || 0,
    }
  })

  // STEP 4: bygg user prompt med numrerade sources + roll-specifik TRIAD
  const trunc = (s: string, n: number) => (s || '').slice(0, n)
  const sourceBlocks = sources
    .map((s) => {
      const parts = [
        `[${s.idx}] "${s.title}" (${s.journal}, ${s.year}, id=${s.id})`,
        `    Core claim: ${trunc(s.core_claim, 300)}`,
      ]
      if (s.episteme)  parts.push(`    Episteme (what research establishes): ${trunc(s.episteme, 400)}`)
      if (s.techne)    parts.push(`    Techne (how to apply): ${trunc(s.techne, 400)}`)
      if (s.phronesis) parts.push(`    Phronesis (situated judgment): ${trunc(s.phronesis, 400)}`)
      if (s.limitation) parts.push(`    Limitation: ${trunc(s.limitation, 200)}`)
      return parts.join('\n')
    })
    .join('\n\n')
  const userPrompt = `QUESTION (from ${roleHuman}): ${query}

SOURCES (peer-reviewed articles ranked by semantic similarity to the question):

${sourceBlocks}

Now synthesize a JSON answer following STRICT RULES.`

  // STEP 5: Anthropic Sonnet 4.6
  const antRes = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': ANTHROPIC_KEY,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({
      model: 'claude-sonnet-4-6',
      max_tokens: 1200,
      system: buildSystemPrompt(lang),
      messages: [{ role: 'user', content: userPrompt }],
    }),
  })
  if (!antRes.ok) {
    const eBody = await antRes.text()
    console.error('sonnet error:', antRes.status, eBody.slice(0, 300))
    return json({ status: 'error', error: `sonnet: ${antRes.status}` }, 502)
  }
  const antData = await antRes.json()
  const txt = antData?.content?.[0]?.text || ''

  // STEP 6: parse JSON (defensiv — hantera ```json-fences om Sonnet råkar lägga dem)
  let parsed: any = null
  try {
    const cleaned = txt.replace(/^```json\s*/, '').replace(/```\s*$/, '').trim()
    parsed = JSON.parse(cleaned)
  } catch (_) {
    const m = txt.match(/\{[\s\S]*\}/)
    if (m) { try { parsed = JSON.parse(m[0]) } catch (__) {} }
  }
  if (!parsed || typeof parsed !== 'object') {
    console.error('parse_failed txt:', txt.slice(0, 300))
    return json({ status: 'error', error: 'parse_failed', raw: txt.slice(0, 300) }, 500)
  }

  // STEP 7: LLM self-reported insufficient coverage
  if (parsed.coverage_note === 'insufficient' || !parsed.answer || !String(parsed.answer).trim()) {
    return json({
      status: 'insufficient_coverage',
      message: L(
        `Baserat på de hittade artiklarna finns inte tillräckligt underlag för att besvara frågan säkert för ${roleHuman}.`,
        `Based on the retrieved articles, there is not enough evidence to answer this question reliably for ${roleHuman}.`
      ),
      reason: 'llm_insufficient',
      hits_summary: sources.map((s) => ({ article_id: s.id, title: s.title, similarity: s.similarity })),
    })
  }

  // STEP 8: validera citations — refs måste (a) finnas i sources och
  // (b) faktiskt förekomma inline som [N] i answer. Utan (b) kunde Sonnet
  // lista en referens den aldrig använde och användaren tolkade det som
  // extra evidens. (Q1 2026-07-23: [5] i array men aldrig i text.)
  const validRefs = new Set(sources.map((s) => s.idx))
  const answerText = String(parsed.answer)
  const rawCitations = Array.isArray(parsed.citations) ? parsed.citations : []
  const enrichedCitations = rawCitations
    .filter((c: any) => {
      const ref = Number(c?.ref)
      return validRefs.has(ref) && answerText.includes(`[${ref}]`)
    })
    .map((c: any) => {
      const ref = Number(c.ref)
      const src = sources.find((s) => s.idx === ref)!
      return {
        ref,
        article_id: src.id,
        title: src.title,
        journal: src.journal,
        year: src.year,
      }
    })

  return json({
    status: 'answer',
    answer: String(parsed.answer),
    citations: enrichedCitations,
    confidence: ['high', 'medium', 'low'].includes(parsed.confidence) ? parsed.confidence : 'medium',
    sources: sources.map((s) => ({
      idx: s.idx,
      id: s.id,
      title: s.title,
      journal: s.journal,
      year: s.year,
      similarity: s.similarity,
      core_claim: s.core_claim,
    })),
    role: dbRole,
    // Free-user: 0-2 (efter denna claim). Pro: null (ingen count-badge).
    // ORDER 112 — frontend renderar "N free left today" under answer om ej null.
    quota_remaining: quotaRemainingForClient,
    duration_ms: Date.now() - startedAt,
  })
})
