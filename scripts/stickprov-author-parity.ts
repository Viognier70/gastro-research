#!/usr/bin/env -S deno run --allow-net --allow-env
// scripts/stickprov-author-parity.ts
//
// READ-ONLY diagnostik. Två frågor i en körning:
//
//   A) Är OpenAlex-parsern buggad? 20 rader med source='openalex' och
//      authors utan komma (singelnamn). Slår upp DOI:n mot
//      api.openalex.org/works/doi:<doi> och jämför authorships[]-längd
//      mot vad vi lagrat.
//
//   B) Kan OpenAlex laga de 13 540 Scopus-raderna med truncerad authors?
//      Samma uppslag för 20 rader med source='scopus'. Rapporterar hur
//      många som (i) hittas i OpenAlex och (ii) faktiskt har >1 författare
//      i råsvaret. B avgör backfill-strategin — Scopus är avstängd och
//      SCOPUS_KEY saknar COMPLETE-rätt så re-fetch via Scopus är omöjlig.
//
// USAGE:
//   export SERVICE_ROLE_KEY=<key>
//   deno run --allow-net --allow-env scripts/stickprov-author-parity.ts
//   deno run --allow-net --allow-env scripts/stickprov-author-parity.ts --n=50
//
// INGEN DB-SKRIVNING. Rapport skrivs till stdout.

const SB_URL  = Deno.env.get('SUPABASE_URL') || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_KEY  = Deno.env.get('SERVICE_ROLE_KEY') || ''
const MAILTO  = 'anders@crichton-fock.com'
const RATE_MS = 150   // OpenAlex polite pool = 10 req/s hard cap

const N_ARG = Deno.args.find(a => a.startsWith('--n='))
const N = N_ARG ? Math.max(1, parseInt(N_ARG.split('=')[1] || '20')) : 20

if (!SB_KEY) {
  console.error('SERVICE_ROLE_KEY env-var saknas')
  Deno.exit(1)
}

type Row = { id: string; url: string | null; title: string; authors: string; source: string }

async function fetchSingleAuthorRows(source: 'openalex' | 'scopus', limit: number): Promise<Row[]> {
  // PostgREST: authors saknar komma OCH är icke-tom OCH inte null.
  // Ordning "id" (deterministisk) — vi vill inte fylla stickprovet
  // med samma dubbletter mellan körningar.
  // Hämtar lite fler än limit och filtrerar tomma authors i JS — PostgREST-
  // syntaxen för "neq.tomt" är opålitlig cross-version, JS-filtret är säkrare.
  // articles har ingen doi-kolumn; DOI:n ligger inbakad i url som
  // 'https://doi.org/<code>'. extractDoi nedan gör strippningen.
  const qs = [
    'select=id,url,title,authors,source',
    `source=eq.${source}`,
    'authors=not.is.null',
    'authors=not.ilike.*,*',
    `limit=${limit * 2}`,
    'order=id'
  ].join('&')
  const r = await fetch(`${SB_URL}/rest/v1/articles?${qs}`, {
    headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}` }
  })
  if (!r.ok) {
    console.error(`  articles-fetch (${source}) HTTP ${r.status}: ${await r.text()}`)
    return []
  }
  const all: Row[] = await r.json()
  return all.filter(x => x.authors && x.authors.trim()).slice(0, limit)
}

// Extrahera raw DOI ur url-fältet. Rader vars url inte matchar doi.org
// (t.ex. openalex.org/W…, Scopus prism:url utan DOI) returnerar '' —
// callern räknar dem som ej-lagbara.
function extractDoi(row: Row): string {
  const raw = (row.url || '').trim()
  if (!/^https?:\/\/(?:dx\.)?doi\.org\//i.test(raw)) return ''
  let s = raw
  while (/^https?:\/\/(?:dx\.)?doi\.org\//i.test(s)) {
    s = s.replace(/^https?:\/\/(?:dx\.)?doi\.org\//i, '')
  }
  return s
}

type OaResult = { hit: boolean; nAuthors: number; status: number; sample: string }

async function openAlexByDoi(doi: string): Promise<OaResult> {
  if (!doi) return { hit: false, nAuthors: 0, status: 0, sample: '' }
  const url = `https://api.openalex.org/works/doi:${encodeURIComponent(doi)}?mailto=${MAILTO}`
  try {
    const r = await fetch(url, { headers: { 'User-Agent': 'GustoScience-diag/1.0' } })
    if (r.status === 404) return { hit: false, nAuthors: 0, status: 404, sample: '' }
    if (!r.ok) return { hit: false, nAuthors: 0, status: r.status, sample: '' }
    const d = await r.json()
    const authorships = d.authorships || []
    const names = authorships.map((a: any) => a.author?.display_name || '').filter(Boolean)
    return {
      hit: true,
      nAuthors: names.length,
      status: 200,
      sample: names.slice(0, 3).join(', ') + (names.length > 3 ? ', …' : '')
    }
  } catch (e) {
    console.error(`  openalex ${doi} error:`, (e as Error).message)
    return { hit: false, nAuthors: 0, status: -1, sample: '' }
  }
}

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms))

function truncate(s: string, n: number): string {
  if (!s) return ''
  return s.length > n ? s.slice(0, n - 1) + '…' : s
}

// ─── (A) OPENALEX-PARSERN ──────────────────────────────────────────────────────

async function runA(): Promise<void> {
  console.log('\n=== A) OpenAlex-parsern — är den buggad? ===')
  console.log(`Målpopulation: source=openalex, authors utan komma. Sampel: ${N}\n`)
  const rows = await fetchSingleAuthorRows('openalex', N)
  if (rows.length === 0) { console.log('  0 rader.'); return }

  const results: Array<{ row: Row; doi: string; oa: OaResult | null }> = []
  for (const row of rows) {
    const doi = extractDoi(row)
    const oa = doi ? await openAlexByDoi(doi) : null
    results.push({ row, doi, oa })
    if (doi) await sleep(RATE_MS)
  }

  console.log('#   Stored authors            OA-len  OA-sample                                Verdict')
  console.log('─'.repeat(115))
  let bug = 0, mismatch = 0, ok = 0, notfound = 0, nodoi = 0
  results.forEach(({ row, doi, oa }, i) => {
    let verdict = ''
    if (!doi) { verdict = 'no DOI i url'; nodoi++ }
    else if (!oa!.hit) { verdict = `not in OA (${oa!.status})`; notfound++ }
    else if (oa!.nAuthors > 1) { verdict = `⚠ parser tappade ${oa!.nAuthors - 1}`; bug++ }
    else if (oa!.nAuthors === 1) { verdict = 'OK (verkligt singel)'; ok++ }
    else { verdict = 'OA 0 authorships (?)'; mismatch++ }
    console.log(
      `${String(i + 1).padEnd(4)}` +
      truncate(row.authors, 25).padEnd(26) +
      String(oa?.nAuthors ?? '-').padEnd(8) +
      truncate(oa?.sample ?? '', 40).padEnd(41) +
      verdict
    )
  })
  console.log('─'.repeat(115))
  console.log(`Sammanfattning: ${bug}/${rows.length} bug (OA har >1, vi lagrade 1)`)
  console.log(`                ${ok}/${rows.length} verklig singelförfattare (ingen bug)`)
  console.log(`                ${notfound}/${rows.length} DOI finns men inte i OpenAlex`)
  console.log(`                ${nodoi}/${rows.length} url saknar doi.org — inte uppslagningsbara`)
  if (mismatch) console.log(`                ${mismatch}/${rows.length} udda (OA returnerade 0)`)
}

// ─── (B) OPENALEX SOM SCOPUS-RÄDDNING ─────────────────────────────────────────

async function runB(): Promise<void> {
  console.log('\n\n=== B) Kan OpenAlex laga Scopus-raderna? ===')
  console.log(`Målpopulation: source=scopus, authors utan komma (subset av 13 540). Sampel: ${N}\n`)
  const rows = await fetchSingleAuthorRows('scopus', N)
  if (rows.length === 0) { console.log('  0 rader.'); return }

  const results: Array<{ row: Row; doi: string; oa: OaResult | null }> = []
  for (const row of rows) {
    const doi = extractDoi(row)
    const oa = doi ? await openAlexByDoi(doi) : null
    results.push({ row, doi, oa })
    if (doi) await sleep(RATE_MS)
  }

  console.log('#   Stored authors            DOI-hit    OA-len  OA-sample')
  console.log('─'.repeat(115))
  let hit = 0, hitMulti = 0, hitSingle = 0, miss = 0, nodoi = 0
  results.forEach(({ row, doi, oa }, i) => {
    let hitMark: string
    if (!doi) { hitMark = 'no-doi'; nodoi++ }
    else if (oa!.hit) {
      hitMark = '✓'
      hit++
      if (oa!.nAuthors > 1) hitMulti++
      else if (oa!.nAuthors === 1) hitSingle++
    } else {
      hitMark = `× (${oa!.status})`
      miss++
    }
    console.log(
      `${String(i + 1).padEnd(4)}` +
      truncate(row.authors, 25).padEnd(26) +
      hitMark.padEnd(11) +
      String(oa?.nAuthors ?? '-').padEnd(8) +
      truncate(oa?.sample ?? '', 55)
    )
  })
  console.log('─'.repeat(115))
  const total = rows.length
  const hitPct = (100 * hit / total).toFixed(1)
  const multiPct = (100 * hitMulti / total).toFixed(1)
  const nodoiPct = (100 * nodoi / total).toFixed(1)
  console.log(`Sammanfattning: ${hit}/${total} (${hitPct} %) DOI finns och hittas i OpenAlex`)
  console.log(`                ${hitMulti}/${total} (${multiPct} %) räddningsbara (har fler än 1 författare där)`)
  if (hitSingle) console.log(`                ${hitSingle}/${total} finns i OA men är också singel — ingen räddning`)
  console.log(`                ${miss}/${total} DOI finns men saknas i OpenAlex`)
  console.log(`                ${nodoi}/${total} (${nodoiPct} %) url saknar doi.org — inte uppslagningsbara, ej lagbara`)
  console.log()
  console.log(`Extrapolerat: ${multiPct} % räddningsbara → ~${Math.round(13540 * hitMulti / total).toLocaleString('sv-SE')} av 13 540 Scopus-rader lagbara via OpenAlex-backfill`)
  console.log(`             ${nodoiPct} % (${Math.round(13540 * nodoi / total).toLocaleString('sv-SE')} rader) har url utan doi.org och är oåtkomliga oavsett strategi`)
}

// ─── KÖR ──────────────────────────────────────────────────────────────────────

await runA()
await runB()
console.log('\nKlart. Ingen DB-skrivning gjord.\n')
