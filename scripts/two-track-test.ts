// scripts/two-track-test.ts
// ─────────────────────────────────────────────────────────────────────────
// ORDER 103 (Order 1 av 4 i meta-ordern 2026-08-19) — Tiotestet
//
// FRISTÅENDE testskript. Skriver INTE till databasen. Rör INGA edge-fns.
// Skriver en markdownfil (out/two-track-test.md) för manuell granskning.
//
// URVAL: 10 artiklar valda enligt Anders spec (2 metodrika, 2 tunna,
// 2 livsmedelskemi/sensorik, 2 beteende/upplevelse, 1 översikt, 1 specifik).
// FÖR VARJE: kör systemprompten nedan för rollerna sommelier OCH fb_manager.
// Totalt 20 anrop mot claude-sonnet-4-6, max_tokens 1500.
//
// KÖRNING:
//   ANTHROPIC_API_KEY=sk-ant-... \
//   SUPABASE_SERVICE_ROLE_KEY=eyJ... \
//   deno run --allow-net --allow-env --allow-read --allow-write \
//     scripts/two-track-test.ts
//
// Efter körning: läs out/two-track-test.md. Granska varje analogi mot
// abstractet ovanför. Räkna hur många av de 60 fälten (20 × 3) som har
// en analogisk rendering som faktiskt vilar på abstractet — grenen är
// inte redo under 70 %.
// ─────────────────────────────────────────────────────────────────────────

// ── Konfiguration ─────────────────────────────────────────────────────────
const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') || ''
const SB_URL        = Deno.env.get('SUPABASE_URL') || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_KEY        = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''

const MODEL         = 'claude-sonnet-4-6'
const MAX_TOKENS    = 1500
const OUT_PATH      = 'out/two-track-test.md'
const SPECIFIC_DOI  = '10.1080/09571264.2024.2310307'  // The Imitation Game

// Sonnet 4.6 prislista (per 1M tokens). Justera om det ändras.
const PRICE_INPUT_PER_M  = 3
const PRICE_OUTPUT_PER_M = 15

// ── Envcheck ──────────────────────────────────────────────────────────────
if (!ANTHROPIC_KEY || !SB_KEY) {
  console.error('Missing env: ANTHROPIC_API_KEY och SUPABASE_SERVICE_ROLE_KEY krävs.')
  Deno.exit(2)
}

// ── Prompten (ordagrann, ändras INTE) ─────────────────────────────────────
function systemPromptFor(roleLabel: string): string {
  return `You are reading a research abstract for a working ${roleLabel} and
producing TWO renderings of each finding, held against each other.

EXPLICIT: what the study measured, found, or established. Plain,
specific, no hedging adverbs. If the abstract does not support a field,
say so in one short sentence — not a paragraph.

ANALOGICAL: the same finding rendered as an image, comparison or
gesture that a working ${roleLabel} would recognise.

Hard rules for the analogical rendering:
- It must be traceable. Every analogy must rest on something the
  abstract actually states. If you cannot point to the sentence it
  came from, delete it.
- No sensory adjectives about wine or food. Words like silky,
  seductive, elegant, harmonious, symphony, journey are forbidden.
- No analogy that would fit any study. If it could be pasted onto a
  different paper, it is empty — rewrite it.
- One image per field. Do not stack metaphors.
- It is better to write nothing than to write decoration.

Return exactly:
{
  "framing":   { "explicit": "...", "analogical": "..." },
  "practice":  { "explicit": "...", "analogical": "..." },
  "perception":{ "explicit": "...", "analogical": "..." },
  "source_lines": ["the abstract sentence each analogy rests on"]
}`
}

// ── Typer ─────────────────────────────────────────────────────────────────
type Article = {
  id: string
  title: string
  abstract: string
  year: string | null
  topic: string | null
  url: string | null   // DOI lever här som https://doi.org/<doi> — det finns ingen `doi`-kolumn
  bucket: string       // vilket urvals-kriterium den valdes för
  why: string          // kort motivering
}

// DOI extraherad ur url. Returnerar tom sträng om inte en doi.org-url.
function doiFromUrl(url: string | null | undefined): string {
  if (!url) return ''
  const m = /^https?:\/\/(?:dx\.)?doi\.org\/(.+)$/i.exec(url.trim())
  return m ? m[1] : ''
}

type Generation = {
  role: string
  raw: string
  parsed: Record<string, unknown> | null
  timeMs: number
  costUsd: number
  inputTokens: number
  outputTokens: number
  error?: string
}

const ROLES: Array<{key: string, label: string}> = [
  { key: 'sommelier', label: 'sommelier' },
  { key: 'fb_manager', label: 'F&B manager' },
]

// ── Supabase read (service_role, direkt mot public.articles) ──────────────
async function sbSelect(url: string): Promise<any[]> {
  const r = await fetch(url, {
    headers: {
      'apikey': SB_KEY,
      'Authorization': `Bearer ${SB_KEY}`,
    }
  })
  if (!r.ok) {
    const t = await r.text().catch(() => '<unread>')
    throw new Error(`Supabase ${r.status}: ${t.slice(0,200)}`)
  }
  return await r.json()
}

// ── Urval ─────────────────────────────────────────────────────────────────
function wordCount(s: string): number {
  return (s || '').trim().split(/\s+/).filter(Boolean).length
}
function looksMethodRich(a: {abstract: string}): boolean {
  const s = (a.abstract || '').toLowerCase()
  return /\b(method|methods|protocol|design|participants|sample|n\s*=|randomi[sz]ed|controlled|blind|regression|anova|mixed[- ]effects|coding scheme|inter[- ]rater)\b/.test(s)
}
function looksReview(a: {title: string, abstract: string}): boolean {
  const s = ((a.title || '') + ' ' + (a.abstract || '')).toLowerCase()
  return /\b(systematic review|meta[- ]analysis|meta[- ]synthesis|scoping review|literature review|umbrella review)\b/.test(s)
}

const CHEM_TOPICS = new Set(['flavor_science','food_science','sensory_evaluation','sensory_training','fermentation_science','nutritional_science','food_technology'])
const BEHAV_TOPICS = new Set(['food_psychology','food_behavior','experiential_dining','multisensory','atmospherics','servicescape','food_anthropology','crossmodal','appetite_research'])

function pickOne<T>(pool: T[], used: Set<string>, key: (x: T) => string): T | null {
  for (const item of pool) {
    if (!used.has(key(item))) { used.add(key(item)); return item }
  }
  return null
}

async function selectArticles(): Promise<Article[]> {
  console.log('[urval] hämtar bulk från public.articles (service_role, id,title,abstract,year,topic,url)…')
  // Läs en generös bulk att filtrera från. Bara med icke-tomt abstract.
  // Slumpmässig ordning så inte alltid samma toppartiklar plockas.
  //
  // OBS: kolumnen är `url` (inte `doi`). DOI extraheras via doiFromUrl().
  // Läser dessutom specifikt DOI-artikeln separat (url=ilike) så den fyller
  // sin bucket även om den råkar hamna utanför de första 2000 raderna.
  const bulk = await sbSelect(
    `${SB_URL}/rest/v1/articles?select=id,title,abstract,year,topic,url`
    + `&abstract=not.is.null&title=not.is.null&order=id&limit=2000`
  )
  console.log(`[urval] ${bulk.length} kandidater lästa`)

  // Shuffle för slumpmässighet inom bucket-urval
  bulk.sort(() => Math.random() - 0.5)

  const picked: Article[] = []
  const used = new Set<string>()

  // Bucket 1: specifik DOI (fyll först, om den finns). Först: kolla om
  // artikeln råkar ligga i bulk-samplet. Om inte, hämta separat via
  // url=ilike (dubbeltäck så vi garanterat får den).
  let specific = bulk.find(a => doiFromUrl(a.url).toLowerCase() === SPECIFIC_DOI.toLowerCase())
  if (!specific) {
    const extra = await sbSelect(
      `${SB_URL}/rest/v1/articles?select=id,title,abstract,year,topic,url`
      + `&url=ilike.%2A${encodeURIComponent(SPECIFIC_DOI)}%2A&abstract=not.is.null&limit=1`
    ).catch(() => [])
    if (extra.length) specific = extra[0]
  }
  if (specific) {
    used.add(specific.id)
    picked.push({...specific, bucket:'specific-doi', why:`DOI = ${SPECIFIC_DOI} (the imitation game)`})
    console.log(`[urval] specifik DOI hittad: ${specific.title.slice(0,80)}`)
  } else {
    console.warn(`[urval] SPECIFIC_DOI ${SPECIFIC_DOI} finns inte i articles — hoppar över`)
  }

  // Bucket 2: översikt/metaanalys — 1
  const reviewPool = bulk.filter(a => !used.has(a.id) && looksReview(a) && wordCount(a.abstract) >= 60)
  const rv = pickOne(reviewPool, used, x => x.id)
  if (rv) picked.push({...rv, bucket:'review', why:'title/abstract nämner review eller meta-analysis'})

  // Bucket 3: långt metodrikt — 2
  const methodPool = bulk.filter(a => !used.has(a.id) && wordCount(a.abstract) >= 200 && looksMethodRich(a))
  for (let i = 0; i < 2; i++) {
    const m = pickOne(methodPool, used, x => x.id)
    if (m) picked.push({...m, bucket:'method-rich', why:`abstract ≥200 ord + metod-signaler (n=${wordCount(m.abstract)} ord)`})
  }

  // Bucket 4: tunt abstract (<100 ord) — 2
  const thinPool = bulk.filter(a => !used.has(a.id) && wordCount(a.abstract) < 100 && wordCount(a.abstract) >= 15)
  for (let i = 0; i < 2; i++) {
    const t = pickOne(thinPool, used, x => x.id)
    if (t) picked.push({...t, bucket:'thin-abstract', why:`abstract <100 ord (n=${wordCount(t.abstract)} ord)`})
  }

  // Bucket 5: livsmedelskemi/sensorik — 2
  const chemPool = bulk.filter(a => !used.has(a.id) && CHEM_TOPICS.has(a.topic) && wordCount(a.abstract) >= 60)
  for (let i = 0; i < 2; i++) {
    const c = pickOne(chemPool, used, x => x.id)
    if (c) picked.push({...c, bucket:'chem-sensory', why:`topic=${c.topic}`})
  }

  // Bucket 6: beteende/upplevelse — 2
  const behavPool = bulk.filter(a => !used.has(a.id) && BEHAV_TOPICS.has(a.topic) && wordCount(a.abstract) >= 60)
  for (let i = 0; i < 2; i++) {
    const b = pickOne(behavPool, used, x => x.id)
    if (b) picked.push({...b, bucket:'behavior-experience', why:`topic=${b.topic}`})
  }

  // Om ordern på 10 inte uppfylls, fyll med random-eligible.
  while (picked.length < 10) {
    const fill = pickOne(bulk.filter(a => !used.has(a.id) && wordCount(a.abstract) >= 40), used, x => x.id)
    if (!fill) break
    picked.push({...fill, bucket:'fill', why:`fyllnad (specifika buckets tomma)`})
  }

  return picked
}

// ── Claude-anrop ──────────────────────────────────────────────────────────
async function callClaude(system: string, userText: string): Promise<{
  raw: string, timeMs: number, inputTokens: number, outputTokens: number, error?: string
}> {
  const t0 = performance.now()
  try {
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'x-api-key': ANTHROPIC_KEY,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: MAX_TOKENS,
        system,
        messages: [{ role: 'user', content: userText }],
      })
    })
    const timeMs = performance.now() - t0
    if (!r.ok) {
      const body = await r.text().catch(() => '<unread>')
      return { raw:'', timeMs, inputTokens:0, outputTokens:0, error:`HTTP ${r.status}: ${body.slice(0,300)}` }
    }
    const json = await r.json()
    const raw = (json?.content?.[0]?.text) || ''
    const inputTokens = json?.usage?.input_tokens ?? 0
    const outputTokens = json?.usage?.output_tokens ?? 0
    return { raw, timeMs, inputTokens, outputTokens }
  } catch (e) {
    return { raw:'', timeMs: performance.now() - t0, inputTokens:0, outputTokens:0, error: (e as Error).message }
  }
}

function tryParseJson(raw: string): Record<string, unknown> | null {
  // Modellen kan wrappa i ```json ... ``` eller lägga preamble.
  const stripped = raw.replace(/^```(?:json)?\s*/i,'').replace(/```\s*$/,'').trim()
  try { return JSON.parse(stripped) } catch(_) { /* fall through */ }
  // Hitta första { och sista } och försök igen
  const first = stripped.indexOf('{')
  const last = stripped.lastIndexOf('}')
  if (first >= 0 && last > first) {
    try { return JSON.parse(stripped.slice(first, last+1)) } catch(_) {}
  }
  return null
}

function costOf(inTok: number, outTok: number): number {
  return (inTok * PRICE_INPUT_PER_M + outTok * PRICE_OUTPUT_PER_M) / 1_000_000
}

// ── Markdown-utfil ────────────────────────────────────────────────────────
function mdEscape(s: string): string {
  return String(s ?? '').replace(/\|/g,'\\|')
}
function fmtField(name: string, obj: any): string {
  if (!obj || typeof obj !== 'object') return `**${name}:** _(inte returnerat)_`
  const ex = String(obj.explicit ?? '').trim()
  const an = String(obj.analogical ?? '').trim()
  return `**${name}:**
- explicit — ${ex || '_(tomt)_'}
- analogical — ${an || '_(tomt)_'}`
}

async function main() {
  console.log(`[start] model=${MODEL}, max_tokens=${MAX_TOKENS}`)
  const arts = await selectArticles()
  console.log(`[urval] valde ${arts.length} artiklar:`)
  for (const a of arts) {
    console.log(`  - [${a.bucket}] ${a.title.slice(0,80)}  (${a.why})`)
  }
  if (arts.length < 10) {
    console.warn(`[urval] VARNING: bara ${arts.length} artiklar valda, ordern kräver 10`)
  }

  const lines: string[] = []
  lines.push(`# Two-Track Test — ${new Date().toISOString().slice(0,10)}`)
  lines.push('')
  lines.push(`Modell: **${MODEL}**, max_tokens **${MAX_TOKENS}**, temperatur default.`)
  lines.push('')
  lines.push('Testet kör exakt den systemprompt Anders specificerade i ORDER 103.')
  lines.push('Ingen post-processing. Ingen deploy. Ingen DB-skrivning.')
  lines.push('')
  lines.push(`## Urval (${arts.length} artiklar)`)
  lines.push('')
  lines.push('| # | Bucket | Titel | Varför valda |')
  lines.push('|---|---|---|---|')
  arts.forEach((a, i) => {
    lines.push(`| ${i+1} | ${a.bucket} | ${mdEscape(a.title.slice(0,120))} | ${mdEscape(a.why)} |`)
  })
  lines.push('')
  lines.push('---')
  lines.push('')

  let totalCost = 0
  let totalTime = 0
  let totalCalls = 0
  const failedParses: string[] = []

  for (let i = 0; i < arts.length; i++) {
    const a = arts[i]
    console.log(`\n[${i+1}/${arts.length}] ${a.title.slice(0,60)}`)
    lines.push(`## ${i+1}. ${a.title}`)
    lines.push('')
    lines.push(`- **id:** \`${a.id}\``)
    const doi = doiFromUrl(a.url)
    lines.push(`- **doi:** ${doi || '_(url inte doi.org)_'}${a.url ? ` · **url:** ${a.url}` : ''}`)
    lines.push(`- **year:** ${a.year || '_(saknas)_'} · **topic:** ${a.topic || '_(saknas)_'}`)
    lines.push(`- **bucket:** ${a.bucket} — ${a.why}`)
    lines.push('')
    lines.push('### Abstract')
    lines.push('')
    lines.push('> ' + a.abstract.replace(/\n+/g,'\n> '))
    lines.push('')

    const generations: Generation[] = []
    for (const role of ROLES) {
      const sys = systemPromptFor(role.label)
      const user = `Article title: ${a.title}\n\nAbstract:\n${a.abstract}`
      const res = await callClaude(sys, user)
      totalCalls++
      totalTime += res.timeMs
      const cost = costOf(res.inputTokens, res.outputTokens)
      totalCost += cost
      const parsed = res.raw ? tryParseJson(res.raw) : null
      if (!parsed && !res.error) failedParses.push(`${a.id} × ${role.key}`)
      generations.push({
        role: role.key,
        raw: res.raw,
        parsed,
        timeMs: res.timeMs,
        costUsd: cost,
        inputTokens: res.inputTokens,
        outputTokens: res.outputTokens,
        error: res.error,
      })
      console.log(`  · ${role.key}: ${Math.round(res.timeMs)}ms, ${res.inputTokens}+${res.outputTokens} tok, $${cost.toFixed(4)}${res.error ? ' — '+res.error : parsed ? '' : ' — parse-fail'}`)
    }

    for (const g of generations) {
      lines.push(`### Rendering — role: \`${g.role}\``)
      lines.push('')
      lines.push(`_time: ${Math.round(g.timeMs)}ms · tokens: ${g.inputTokens}+${g.outputTokens} · cost: $${g.costUsd.toFixed(4)}_`)
      lines.push('')
      if (g.error) {
        lines.push(`**API-fel:** \`${g.error}\``)
      } else if (!g.parsed) {
        lines.push('**JSON parse-fail. Råsvar:**')
        lines.push('')
        lines.push('```')
        lines.push(g.raw.slice(0, 2000))
        lines.push('```')
      } else {
        const p = g.parsed
        lines.push(fmtField('framing', p.framing))
        lines.push('')
        lines.push(fmtField('practice', p.practice))
        lines.push('')
        lines.push(fmtField('perception', p.perception))
        lines.push('')
        const sl = (p as any).source_lines
        if (Array.isArray(sl) && sl.length) {
          lines.push('**source_lines:**')
          for (const s of sl) lines.push(`- ${String(s).replace(/^[-\s]+/,'').trim()}`)
        } else {
          lines.push('**source_lines:** _(inte returnerat)_')
        }
      }
      lines.push('')
    }
    lines.push('---')
    lines.push('')
  }

  lines.push('')
  lines.push('## Summary')
  lines.push('')
  lines.push(`- Antal anrop: **${totalCalls}**`)
  lines.push(`- Total tid: **${(totalTime/1000).toFixed(1)}s** (snitt ${Math.round(totalTime/Math.max(1,totalCalls))}ms/anrop)`)
  lines.push(`- Total kostnad: **$${totalCost.toFixed(3)}**  (~$${(totalCost/Math.max(1,totalCalls)).toFixed(4)}/anrop)`)
  lines.push(`- JSON parse-fail: ${failedParses.length}${failedParses.length ? ' — ' + failedParses.slice(0,10).join(', ') : ''}`)
  lines.push('')
  lines.push('## Att kontrollera manuellt')
  lines.push('')
  lines.push('För varje rendering: slå upp meningen i abstractet som `source_lines` pekar på.')
  lines.push('Räkna hur många av de 60 fält-analogier (20 renderings × 3 fält) som faktiskt vilar på abstractet.')
  lines.push('Under 70 % är den analogiska grenen inte redo.')

  await Deno.mkdir('out', { recursive: true }).catch(()=>{})
  await Deno.writeTextFile(OUT_PATH, lines.join('\n') + '\n')
  console.log(`\n[done] skrev ${OUT_PATH}  ·  calls=${totalCalls}  ·  total=$${totalCost.toFixed(3)}  ·  parse-fail=${failedParses.length}`)
}

main().catch(e => {
  console.error('[FATAL]', e)
  Deno.exit(1)
})
