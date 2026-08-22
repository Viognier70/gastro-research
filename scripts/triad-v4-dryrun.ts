// scripts/triad-v4-dryrun.ts
// ────────────────────────────────────────────────────────────────────────────
// Kör v4-prompten (labeled-triad.ts) mot juli-stickprovets 25 artiklar
// (outputs/triad-kvalitetsmatning/stickprov-ids.txt) och skriver resultatet
// till outputs/triad-v4-dryrun/ för manuell granskning. INGEN DB-skrivning.
//
// SYFTE: läs utfallet FÖRE v4-prompten committas. Tre återkommande v3-fel
// vi vill se försvinna:
//   1. "The study establishes..." som mekanisk opener i 21/21 Epistemer
//   2. Hedges ("may suggest", "could indicate") utan att namnge osäkerheten
//   3. Ooöversatt jargong i Techne/Phronesis mot fel rollvokabulär
//
// UTFORMNING:
//   - Importerar buildTriadPrompt/parseLabeledProse/EXPECTED_LABELS från
//     _shared/labeled-triad.ts → samma prompt som edge-fn:erna kommer köra
//     efter commit. Ingen prompt-duplicering.
//   - Per artikel: fetchar title/abstract/insight + gamla v3-fält för alla
//     5 roller från Supabase (service_role, read-only), bygger v4-prompt,
//     anropar Anthropic Sonnet 4.6 direkt (per-anrop, inte Batches — 25 st
//     tar ~6 min och feedback-loopen är värd realtiden).
//   - Skriver outputs/triad-v4-dryrun/<index>-<id>.md med:
//       - metadata (title, url, journal, role som juli-stickprovet drog för)
//       - abstract (första 800 tkn)
//       - alla 15 v4-TRIAD-fält
//       - motsvarande gamla v3-fält för sido-vid-sido-jämförelse
//       - parse-status (missing/too_short/extra) om något
//   - Skriver outputs/triad-v4-dryrun/_summary.md med:
//       - totaltid, kostnadsuppskattning, valideringsstatistik
//       - snabb-check per rule 6/7/8 (opener-mönster + hedges + jargong-signal)
//
// STICKPROV-ORDNING (från gustema-triad-stickprov.md SQL union all):
//   ids[0-4]   → sensory_pro
//   ids[5-9]   → culinary_pro
//   ids[10-14] → gastronomy_culture
//   ids[15-19] → hospitality_mgmt
//   ids[20-24] → educator_researcher
//
// MILJÖ:
//   ANTHROPIC_API_KEY            — Anthropic-nyckel
//   SUPABASE_URL                 — default: projekt-URL:en
//   SUPABASE_SERVICE_ROLE_KEY    — service_role för läs-bypass
//
// KÖRNING:
//   deno run --allow-net --allow-env --allow-read --allow-write \
//     scripts/triad-v4-dryrun.ts
// ────────────────────────────────────────────────────────────────────────────

import {
  buildTriadPrompt,
  parseLabeledProse,
  validateTriad,
  EXPECTED_LABELS,
  ROLES,
  type Role,
} from '../supabase/functions/_shared/labeled-triad.ts'

const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') || ''
const SB_URL        = Deno.env.get('SUPABASE_URL')      || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_KEY        = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''

const MODEL      = 'claude-sonnet-4-6'
const MAX_TOKENS = 4000
const STICKPROV  = 'outputs/triad-kvalitetsmatning/stickprov-ids.txt'
const OUT_DIR    = 'outputs/triad-v4-dryrun'

if (!ANTHROPIC_KEY) { console.error('ANTHROPIC_API_KEY saknas'); Deno.exit(2) }
if (!SB_KEY)        { console.error('SUPABASE_SERVICE_ROLE_KEY saknas'); Deno.exit(2) }

// Roll per index enligt SQL-ordningen i gustema-triad-stickprov.md
function roleFor(idx: number): Role {
  const stratumSize = 5
  const rIdx = Math.floor(idx / stratumSize)
  return ROLES[rIdx] || 'sensory_pro'
}

type ArticleRow = {
  id: string
  title: string | null
  url: string | null
  journal: string | null
  year: number | null
  abstract: string | null
  insight: string | null
  episteme_sensory_pro: string | null
  techne_sensory_pro: string | null
  phronesis_sensory_pro: string | null
  episteme_culinary_pro: string | null
  techne_culinary_pro: string | null
  phronesis_culinary_pro: string | null
  episteme_gastronomy_culture: string | null
  techne_gastronomy_culture: string | null
  phronesis_gastronomy_culture: string | null
  episteme_hospitality_mgmt: string | null
  techne_hospitality_mgmt: string | null
  phronesis_hospitality_mgmt: string | null
  episteme_educator_researcher: string | null
  techne_educator_researcher: string | null
  phronesis_educator_researcher: string | null
}

async function fetchArticle(id: string): Promise<ArticleRow | null> {
  const fields = [
    'id', 'title', 'url', 'journal', 'year', 'abstract', 'insight',
    ...ROLES.flatMap(r => [`episteme_${r}`, `techne_${r}`, `phronesis_${r}`]),
  ].join(',')
  const url = `${SB_URL}/rest/v1/articles?select=${fields}&id=eq.${encodeURIComponent(id)}`
  const r = await fetch(url, {
    headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}` },
  })
  if (!r.ok) {
    console.error(`  fetch HTTP ${r.status}: ${(await r.text()).slice(0, 160)}`)
    return null
  }
  const rows = await r.json() as ArticleRow[]
  return rows[0] || null
}

async function callSonnet(prompt: string): Promise<{ ok: true, text: string, usage: any } | { ok: false, error: string, status: number }> {
  const r = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-api-key': ANTHROPIC_KEY,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: MAX_TOKENS,
      messages: [{ role: 'user', content: prompt }],
    }),
  })
  if (!r.ok) return { ok: false, error: (await r.text()).slice(0, 400), status: r.status }
  const j = await r.json()
  const text = (j.content || []).map((b: any) => b?.text || '').join('')
  return { ok: true, text, usage: j.usage || {} }
}

// Heuristiker för rule 6/7/8 — grov signal, inte auktoritativ granskning.
function analyzeOutput(fields: Record<string, string>) {
  const epistemes = ROLES.map(r => fields[`EPISTEME_${r.toUpperCase()}`] || '')
  const openers = epistemes.map(e => e.trim().split(/[\s.]+/).slice(0, 3).join(' ').toLowerCase())
  const uniqueOpeners = new Set(openers).size
  const reportFramePattern = /\b(?:the study|this study|the research|the paper|the authors)\s+(?:establish|find|show|demonstrat|report|document|identif|reveal)/i
  const reportFrameHits = epistemes.filter(e => reportFramePattern.test(e)).length

  const allTechnePhronesis = ROLES.flatMap(r => [
    fields[`TECHNE_${r.toUpperCase()}`] || '',
    fields[`PHRONESIS_${r.toUpperCase()}`] || '',
  ])
  // Vaga hedges = förekomst utan att någon av dessa "grunding-signaler" följer i samma mening
  const vagueHedgeHits: string[] = []
  const hedgePattern = /\b(may|could|might|potentially)\b/gi
  const groundingSignals = /\b(sample size|single[- ]study|correlational|animal model|in vitro|lab|laboratory|not tested|only tested|no replication|absent|limited to|generalize|extrapolate|scale)\b/i
  for (const text of allTechnePhronesis) {
    const sentences = text.split(/(?<=[.!?])\s+/)
    for (const s of sentences) {
      if (hedgePattern.test(s) && !groundingSignals.test(s)) {
        vagueHedgeHits.push(s.trim().slice(0, 140))
      }
    }
  }

  const wordCounts = EXPECTED_LABELS
    .filter(l => l.startsWith('EPISTEME_') || l.startsWith('TECHNE_') || l.startsWith('PHRONESIS_'))
    .map(l => ({ label: l, words: (fields[l] || '').split(/\s+/).filter(Boolean).length }))

  return {
    uniqueOpeners,
    reportFrameHits,
    vagueHedgeHits: vagueHedgeHits.slice(0, 6),
    wordCountRange: {
      min: Math.min(...wordCounts.map(w => w.words)),
      max: Math.max(...wordCounts.map(w => w.words)),
      avg: Math.round(wordCounts.reduce((s, w) => s + w.words, 0) / wordCounts.length),
    },
  }
}

function renderMd(idx: number, id: string, role: Role, a: ArticleRow, v4Text: string, v4Fields: Record<string, string>, analysis: ReturnType<typeof analyzeOutput>, parseStatus: string | null): string {
  const md: string[] = []
  md.push(`# ${idx + 1}. ${a.title || '(no title)'}`)
  md.push('')
  md.push(`- **ID**: \`${id}\``)
  md.push(`- **Roll (juli-stickprov drog för)**: \`${role}\``)
  md.push(`- **Journal / år**: ${a.journal || '?'} · ${a.year || '?'}`)
  md.push(`- **URL**: ${a.url || '(saknas)'}`)
  md.push(`- **Parse-status**: ${parseStatus || 'OK'}`)
  md.push('')
  md.push('## Abstract (första 800 tkn)')
  md.push('')
  md.push('> ' + (a.abstract || a.insight || '(saknas)').slice(0, 800).replace(/\n+/g, ' '))
  md.push('')
  md.push('## Heuristik-check (v4-mål)')
  md.push('')
  md.push(`- **Unika Episteme-openers** (5 max): ${analysis.uniqueOpeners} — mål: 5`)
  md.push(`- **Report-frame-öppning** ("The study/authors <verb>"): ${analysis.reportFrameHits}/5 — mål: 0`)
  md.push(`- **Ordbudget TRIAD-fält** (min/max/snitt): ${analysis.wordCountRange.min} / ${analysis.wordCountRange.max} / ${analysis.wordCountRange.avg}`)
  md.push(`- **Vaga hedges** (utan grunding-signal i samma mening): ${analysis.vagueHedgeHits.length}`)
  if (analysis.vagueHedgeHits.length) {
    for (const h of analysis.vagueHedgeHits) md.push(`  - "${h}"`)
  }
  md.push('')
  md.push('## v4-fält (nya)')
  md.push('')
  md.push(`### KNOWLEDGE_EXPLANATION`)
  md.push('')
  md.push(v4Fields.KNOWLEDGE_EXPLANATION || '(missing)')
  md.push('')
  for (const imrad of ['IMRAD_INTRODUCTION', 'IMRAD_METHODS', 'IMRAD_RESULTS', 'IMRAD_DISCUSSION']) {
    md.push(`### ${imrad}`)
    md.push('')
    md.push(v4Fields[imrad] || '(missing)')
    md.push('')
  }
  for (const r of ROLES) {
    md.push(`### Roll: ${r} ${r === role ? ' ← primär för denna artikel' : ''}`)
    md.push('')
    md.push(`**EPISTEME (v4)**  `)
    md.push(v4Fields[`EPISTEME_${r.toUpperCase()}`] || '(missing)')
    md.push('')
    md.push(`**EPISTEME (v3, DB)**  `)
    md.push((a[`episteme_${r}` as keyof ArticleRow] as string) || '(saknas)')
    md.push('')
    md.push(`**TECHNE (v4)**  `)
    md.push(v4Fields[`TECHNE_${r.toUpperCase()}`] || '(missing)')
    md.push('')
    md.push(`**TECHNE (v3, DB)**  `)
    md.push((a[`techne_${r}` as keyof ArticleRow] as string) || '(saknas)')
    md.push('')
    md.push(`**PHRONESIS (v4)**  `)
    md.push(v4Fields[`PHRONESIS_${r.toUpperCase()}`] || '(missing)')
    md.push('')
    md.push(`**PHRONESIS (v3, DB)**  `)
    md.push((a[`phronesis_${r}` as keyof ArticleRow] as string) || '(saknas)')
    md.push('')
  }
  md.push('---')
  md.push('')
  md.push('## Rå Sonnet-output (för debug)')
  md.push('')
  md.push('```')
  md.push(v4Text.slice(0, 8000))
  md.push('```')
  return md.join('\n')
}

async function main() {
  await Deno.mkdir(OUT_DIR, { recursive: true })

  const idsText = await Deno.readTextFile(STICKPROV)
  const ids = idsText.split('\n').map(l => l.trim()).filter(Boolean)
  if (ids.length !== 25) {
    console.error(`Väntade 25 IDs i ${STICKPROV}, hittade ${ids.length}`)
    Deno.exit(3)
  }
  console.log(`Kör v4 mot ${ids.length} artiklar från juli-stickprovet.`)
  console.log(`Output → ${OUT_DIR}/\n`)

  const startedAt = Date.now()
  const stats = {
    ok: 0, parseFail: 0, apiFail: 0,
    totalInputTokens: 0, totalOutputTokens: 0,
    perArticle: [] as Array<{ id: string, role: Role, uniqueOpeners: number, reportFrameHits: number, vagueHedges: number, wordAvg: number, parseStatus: string | null }>,
  }

  for (let i = 0; i < ids.length; i++) {
    const id = ids[i]
    const role = roleFor(i)
    process_stdout(`[${i + 1}/25] ${id.slice(0, 8)}… (${role})`)

    const article = await fetchArticle(id)
    if (!article) { console.log('  ← artikel saknas i DB, hoppar över'); continue }

    const prompt = buildTriadPrompt({
      title: article.title || '',
      abstract: article.abstract || '',
      insight: article.insight || '',
    })

    const res = await callSonnet(prompt)
    if (!res.ok) {
      console.log(`  ← API-fel HTTP ${res.status}`)
      stats.apiFail++
      continue
    }
    stats.totalInputTokens  += res.usage.input_tokens  || 0
    stats.totalOutputTokens += res.usage.output_tokens || 0

    const parsed = parseLabeledProse(res.text)
    const parseStatus = validateTriad(parsed)
    if (parseStatus) stats.parseFail++
    else stats.ok++

    const analysis = analyzeOutput(parsed.fields)
    stats.perArticle.push({
      id, role,
      uniqueOpeners: analysis.uniqueOpeners,
      reportFrameHits: analysis.reportFrameHits,
      vagueHedges: analysis.vagueHedgeHits.length,
      wordAvg: analysis.wordCountRange.avg,
      parseStatus,
    })

    const md = renderMd(i, id, role, article, res.text, parsed.fields, analysis, parseStatus)
    const outFile = `${OUT_DIR}/${String(i + 1).padStart(2, '0')}-${id.slice(0, 8)}.md`
    await Deno.writeTextFile(outFile, md)
    console.log(`  ok (${res.usage.input_tokens || '?'}→${res.usage.output_tokens || '?'} tokens, ${analysis.uniqueOpeners}/5 openers, ${analysis.reportFrameHits} report-frame, ${analysis.vagueHedgeHits.length} vague hedges)`)
  }

  const elapsedS = ((Date.now() - startedAt) / 1000).toFixed(1)

  // Kostnad: Sonnet 4.6 = $3/M input, $15/M output (per 2026-08)
  const cost = (stats.totalInputTokens / 1_000_000) * 3 + (stats.totalOutputTokens / 1_000_000) * 15

  const sum: string[] = []
  sum.push(`# Dry-run v4 — summering`)
  sum.push('')
  sum.push(`- **Körtid**: ${elapsedS} s`)
  sum.push(`- **Modell**: ${MODEL}`)
  sum.push(`- **Artiklar**: ${ids.length} (juli-stickprov)`)
  sum.push(`- **Parse OK**: ${stats.ok} / ${ids.length}`)
  sum.push(`- **Parse-fel**: ${stats.parseFail}`)
  sum.push(`- **API-fel**: ${stats.apiFail}`)
  sum.push(`- **Tokens**: ${stats.totalInputTokens.toLocaleString()} in / ${stats.totalOutputTokens.toLocaleString()} out`)
  sum.push(`- **Uppskattad kostnad**: $${cost.toFixed(3)}`)
  sum.push('')
  sum.push('## Rule-6/7-mätning per artikel')
  sum.push('')
  sum.push('| # | roll | unique openers /5 | report-frame /5 | vaga hedges | ord snitt | parse |')
  sum.push('|---|------|-------------------|-----------------|-------------|-----------|-------|')
  stats.perArticle.forEach((p, i) => {
    sum.push(`| ${i + 1} | ${p.role} | ${p.uniqueOpeners} | ${p.reportFrameHits} | ${p.vagueHedges} | ${p.wordAvg} | ${p.parseStatus || 'ok'} |`)
  })
  sum.push('')
  sum.push('## Tolkning')
  sum.push('')
  sum.push('- **unique openers**: 5 = alla 5 Epistemer har olika 3-ords-öppning. Låga tal = rule 6 svag.')
  sum.push('- **report-frame**: antal Epistemer som ändå öppnar med "The study/authors <verb>". Mål: 0.')
  sum.push('- **vaga hedges**: hedge-ord i mening utan grunding-signal (sample size, in vitro, ...). Heuristiken är grov — den missar vissa hedges och kan falsk-flagga.')
  sum.push('- **ord snitt**: mål 60-80. Om många ligger på 90 kan max behöva justeras uppåt eller innehållet strippas.')
  sum.push('')
  sum.push('Jargong (rule 8) mäts INTE automatiskt — kräver manuell granskning per fält.')

  await Deno.writeTextFile(`${OUT_DIR}/_summary.md`, sum.join('\n'))
  console.log(`\n\nKlart. Summering: ${OUT_DIR}/_summary.md`)
  console.log(`Total: ${elapsedS}s, ${stats.ok}/${ids.length} parse-OK, kostnad ~$${cost.toFixed(3)}`)
}

// Deno saknar 'process' — enkelt inline
function process_stdout(s: string) { Deno.stdout.writeSync(new TextEncoder().encode(s)) }

main().catch(e => { console.error(e); Deno.exit(1) })
