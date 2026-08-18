#!/usr/bin/env -S deno run --allow-net --allow-env
// scripts/backfill-openalex-terms.ts
//
// Backfill av keywords för no-role-artiklar (~13k per 2026-07-17).
//
// Använder SAMMA _shared/openalex-terms.ts som daily-fetch (validerad
// modul: post-deploy-stickprov 15/15 sci-processade, merge fungerar,
// primär räckte för alla; concepts-fallback väntas trigga oftare i
// 13k-svansen där gamla artiklar har färre topics/keywords).
//
// USAGE:
//   Dry-run (DEFAULT: 100 artiklar, ingen DB-skrivning):
//     export SERVICE_ROLE_KEY=<key>
//     deno run --allow-net --allow-env scripts/backfill-openalex-terms.ts
//
//   Live (kräver --live, efter godkännande av dry-run-resultatet):
//     export SERVICE_ROLE_KEY=<key>
//     deno run --allow-net --allow-env scripts/backfill-openalex-terms.ts --live
//
// FLAGGOR:
//   --live       Skriv till DB, kör hela populationen (13k). Utan flaggan
//                körs dry-run mot 100 artiklar.
//   --limit=N    Cappa populationen till N artiklar (fungerar i båda lägen).
//
// GUARD: skriver ENDAST till keywords IS NULL. Idempotent — om något annat
// har skrivit under tiden respekteras det.
//
// RATE LIMIT: OpenAlex polite pool = 10 req/s hard cap. Vi ligger på ~7 req/s
// (RATE_LIMIT_MS=150). 13k / 50 per batch = ~260 batches ≈ 40s API-tid,
// ~11 min wall-clock inkl. DB-skrivningar (~50ms/PATCH).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { openAlexToKeywords, MIN_TERMS } from '../supabase/functions/_shared/openalex-terms.ts'

const SB_URL = Deno.env.get('SUPABASE_URL') || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_KEY = Deno.env.get('SERVICE_ROLE_KEY') || ''
const MAILTO = 'anders@crichton-fock.com'
const BATCH_SIZE = 50
const RATE_LIMIT_MS = 150
const PROGRESS_EVERY = 500

const argsSet = new Set(Deno.args)
const LIVE = argsSet.has('--live')
const LIMIT_ARG = Deno.args.find(a => a.startsWith('--limit='))
const LIMIT = LIMIT_ARG
  ? parseInt(LIMIT_ARG.split('=')[1])
  : (LIVE ? null : 100)

if (!SB_KEY) {
  console.error('SERVICE_ROLE_KEY env-var saknas')
  Deno.exit(1)
}

createClient(SB_URL, SB_KEY, { auth: { persistSession: false } })

// Hämtar målpopulation från articles-tabellen. Or-filter över 5 kolumner
// via rå PostgREST-URL (builder-kedjan blir otymplig här).
async function fetchPopulation(): Promise<Array<{ id: string; url: string; title: string }>> {
  const filters = [
    'select=id,url,title',
    'irrelevant=eq.false',
    'keywords=is.null',
    'url=ilike.*doi.org/*',
    'abstract=not.is.null',
    'and=(or(relevance_sci_sensory_pro.lt.5,relevance_sci_sensory_pro.is.null),' +
      'or(relevance_sci_culinary_pro.lt.5,relevance_sci_culinary_pro.is.null),' +
      'or(relevance_sci_gastronomy_culture.lt.5,relevance_sci_gastronomy_culture.is.null),' +
      'or(relevance_sci_hospitality_mgmt.lt.5,relevance_sci_hospitality_mgmt.is.null),' +
      'or(relevance_sci_educator_researcher.lt.5,relevance_sci_educator_researcher.is.null))',
    'order=fetched_at.desc',
  ]
  if (LIMIT) filters.push(`limit=${LIMIT}`)
  const url = `${SB_URL}/rest/v1/articles?${filters.join('&')}`
  const r = await fetch(url, {
    headers: { 'apikey': SB_KEY, 'Authorization': `Bearer ${SB_KEY}` },
  })
  if (!r.ok) {
    console.error('Population fetch failed:', r.status, await r.text())
    Deno.exit(1)
  }
  return r.json()
}

// Hämtar OpenAlex-payload för en batch DOIer. Returnerar mapping doi→work.
async function fetchOpenAlexBatch(dois: string[]): Promise<Map<string, any>> {
  const filter = 'doi:' + dois.join('|')
  const url = `https://api.openalex.org/works?filter=${encodeURIComponent(filter)}&per-page=${BATCH_SIZE}&mailto=${MAILTO}`
  const r = await fetch(url, { headers: { 'User-Agent': 'GustoScience-backfill/1.0' } })
  if (!r.ok) {
    console.error(`OpenAlex batch failed: ${r.status}`)
    return new Map()
  }
  const d = await r.json()
  const out = new Map<string, any>()
  for (const w of (d.results || [])) {
    const doi = (w.doi || '').replace(/^https?:\/\/doi\.org\//i, '').toLowerCase()
    if (doi) out.set(doi, w)
  }
  return out
}

function urlToDoi(url: string): string {
  return (url || '').replace(/^https?:\/\/doi\.org\//i, '').trim()
}

// Räknar hur många termer primär-källan (topics + keywords) gav genom att
// anropa MODULENS funktion med concepts=[]  — då kan fallback inte trigga
// och resultatet är exakt primär. Vi anropar ALLTID openAlexToKeywords
// (inte en lokal kopia av primär-logiken) så mätningen inte driftar från
// modulen om primär-logiken ändras (lärdom 4).
function primaryTermCountViaModule(work: any): number {
  if (!work) return 0
  return openAlexToKeywords({ ...work, concepts: [] }).length
}

// --- main ---
console.log(`Läge: ${LIVE ? 'LIVE (skriver till DB, guard keywords IS NULL)' : 'DRY-RUN (ingen DB-skrivning)'}`)
console.log(`Limit: ${LIMIT ?? 'ingen (hela populationen)'}`)
console.log(`MIN_TERMS (från modulen): ${MIN_TERMS}\n`)

const articles = await fetchPopulation()
console.log(`Populationsstorlek: ${articles.length}\n`)

let batchCount = 0
let openAlexFound = 0
let openAlexMissing = 0
let withKeywords = 0
let zeroKeywords = 0
let fallbackTriggered = 0
let updated = 0
let updateFailed = 0
const keywordCounts: number[] = []
const startedAt = Date.now()

for (let i = 0; i < articles.length; i += BATCH_SIZE) {
  const chunk = articles.slice(i, i + BATCH_SIZE)
  const dois = chunk.map(a => urlToDoi(a.url)).filter(Boolean)
  const doiToArticle = new Map(chunk.map(a => [urlToDoi(a.url).toLowerCase(), a]))

  const works = await fetchOpenAlexBatch(dois)
  batchCount++

  for (const [doi, work] of works) {
    openAlexFound++
    const article = doiToArticle.get(doi)
    if (!article) continue

    const primaryN = primaryTermCountViaModule(work)
    const keywords = openAlexToKeywords(work)
    const fbTriggered = keywords.length > primaryN

    keywordCounts.push(keywords.length)
    if (keywords.length > 0) withKeywords++
    else zeroKeywords++
    if (fbTriggered) fallbackTriggered++

    if (!LIVE) {
      const fbTag = fbTriggered ? `  FALLBACK+${keywords.length - primaryN}` : ''
      console.log(`  ${article.id.slice(0, 8)} [${keywords.length}kw${fbTag}] "${(article.title || '').slice(0, 55)}"`)
      if (keywords.length > 0) console.log(`     ${keywords.slice(0, 12).join(', ')}${keywords.length > 12 ? ', ...' : ''}`)
    } else {
      if (keywords.length === 0) continue
      // Guard: skriv bara om keywords fortfarande är null. Idempotent —
      // om något annat skrivit under tiden respekteras det.
      const upd = await fetch(
        `${SB_URL}/rest/v1/articles?id=eq.${article.id}&keywords=is.null`,
        {
          method: 'PATCH',
          headers: {
            'apikey': SB_KEY,
            'Authorization': `Bearer ${SB_KEY}`,
            'Content-Type': 'application/json',
            'Prefer': 'return=minimal',
          },
          body: JSON.stringify({ keywords }),
        }
      )
      if (upd.ok) {
        updated++
        if (updated % PROGRESS_EVERY === 0) {
          const elapsed = ((Date.now() - startedAt) / 1000).toFixed(0)
          console.log(`  progress: ${updated} skrivna på ${elapsed}s`)
        }
      } else {
        updateFailed++
        console.error(`Update ${article.id.slice(0, 8)} failed: ${upd.status}`)
      }
    }
  }

  for (const doi of dois) {
    if (!works.has(doi.toLowerCase())) openAlexMissing++
  }

  await new Promise(r => setTimeout(r, RATE_LIMIT_MS))
  if (batchCount % 10 === 0 && !LIVE) {
    console.log(`--- Progress: batch ${batchCount}, ${openAlexFound}/${i + chunk.length} funna, ${zeroKeywords} zero, ${fallbackTriggered} fallback ---`)
  }
}

const elapsed = ((Date.now() - startedAt) / 1000).toFixed(1)
const total = keywordCounts.length
const nz = keywordCounts.filter(c => c > 0)
const avg = total ? (keywordCounts.reduce((a, b) => a + b, 0) / total).toFixed(1) : '0'
const avgNz = nz.length ? (nz.reduce((a, b) => a + b, 0) / nz.length).toFixed(1) : '0'
const sorted = [...keywordCounts].sort((a, b) => a - b)
const median = sorted.length ? sorted[Math.floor(sorted.length / 2)] : 0

console.log(`\n=== SAMMANFATTNING (${elapsed}s, ${batchCount} batches) ===`)
console.log(`Läge:                       ${LIVE ? 'LIVE' : 'DRY-RUN'}`)
console.log(`Population:                 ${articles.length}`)
console.log(`OpenAlex-funna:             ${openAlexFound}  (${(100 * openAlexFound / Math.max(articles.length, 1)).toFixed(1)}%)`)
console.log(`OpenAlex-saknade:           ${openAlexMissing}  (${(100 * openAlexMissing / Math.max(articles.length, 1)).toFixed(1)}%)`)
if (openAlexFound > 0) {
  console.log(`Med 1+ keyword:             ${withKeywords}  (${(100 * withKeywords / openAlexFound).toFixed(1)}% av funna)`)
  console.log(`Zero-keywords:              ${zeroKeywords}  (${(100 * zeroKeywords / openAlexFound).toFixed(1)}% av funna)`)
  console.log(`Fallback triggade:          ${fallbackTriggered}  (${(100 * fallbackTriggered / openAlexFound).toFixed(1)}% av funna)`)
}
console.log(`Snitt kw/artikel (alla):    ${avg}`)
console.log(`Snitt kw/artikel (1+):      ${avgNz}`)
console.log(`Median:                     ${median}`)
if (LIVE) {
  console.log(`DB-skrivna:                 ${updated}`)
  console.log(`Skriv-fel:                  ${updateFailed}`)
} else {
  console.log(`(DRY-RUN — inga skrivningar)`)
}
