// scripts/backfill-empty-journals.ts
//
// ORDER 161 (2026-08-25) — backfill av tomt journal-fält via OpenAlex.
//
// KONTEXT
// -------
// Full-DB-räkning 2026-08-25 gav 356/35 107 rader med journal NULL eller tom
// sträng (irrelevant IS NOT TRUE). Fördelning per source:
//   openalex          333  (re-fetch via OpenAlex Work-ID i url eller DOI)
//   endnote            12  (lookup via api.openalex.org/works/doi:… om url har DOI)
//   semantic_scholar   11  (lookup via api.openalex.org/works/doi:… om url har DOI)
//   scopus              0
//   pubmed              0
//
// Denna backfill re-fetchar från OpenAlex (samma källa som pipelinen och
// samma fallback-kedja som ORDER 161-fixen i daily-fetch:626 — primary_
// location.source.display_name → locations[].source.display_name). Då blir
// backfillade rader identiska med vad pipelinen skulle skriva idag.
//
// endnote/semantic_scholar-raderna: kolla url-fältet för DOI. Har de en DOI
// kan OpenAlex slå upp dem via /works/doi:<doi>. Har de ingen DOI (troligtvis
// arxiv-preprints, thesis-repos etc.) — lämna dem orörda.
//
// ANVÄNDNING
// ----------
//   # Dry-run mot hela populationen (default). Ingen DB-skrivning.
//   deno run --allow-net --allow-env --allow-read \
//     scripts/backfill-empty-journals.ts
//
//   # Test-batch mot första 20 raderna:
//   deno run --allow-net --allow-env --allow-read \
//     scripts/backfill-empty-journals.ts --limit 20
//
//   # Apply — PATCH articles.journal.
//   deno run --allow-net --allow-env --allow-read \
//     scripts/backfill-empty-journals.ts --apply
//
// MILJÖ
// -----
//   SUPABASE_URL               — default: prod-URL
//   SUPABASE_SERVICE_ROLE_KEY  — krävs (RLS bypass för läsning + skrivning)
//   OPENALEX_MAILTO            — email för polite pool (rekommenderat, höjer
//                                 rate-limiten till 10 req/s / 100k req/dygn)
//
// FÖRUTSÄTTNING
// -------------
//   Migration 20260825150000_journal_backup_pre_order_161.sql måste vara
//   applicerad före --apply — annars finns ingen rollback-väg.

const SB_URL = Deno.env.get('SUPABASE_URL') || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
const OPENALEX_MAILTO = Deno.env.get('OPENALEX_MAILTO') || 'anders@crichton-fock.com'

if (!SB_KEY) {
  console.error('SUPABASE_SERVICE_ROLE_KEY not set')
  Deno.exit(1)
}

const args = Deno.args
const apply = args.includes('--apply')
let limit = 0
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--limit' && args[i + 1]) limit = parseInt(args[i + 1]) || 0
}

// Rate-limit: OpenAlex polite pool är ~10 req/s (100k/dygn). 150 ms/req ger
// marginal + tar ~54 s för 356 rader. Snällare mot API:t = lägre chans att bli
// throttlad mitt i en batch.
const REQ_DELAY_MS = 150

type Row = {
  id: string
  url: string | null
  source: string | null
  journal: string | null
}

async function sbFetch(path: string, init: RequestInit = {}): Promise<Response> {
  return await fetch(`${SB_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      'apikey': SB_KEY,
      'Authorization': `Bearer ${SB_KEY}`,
      'Content-Type': 'application/json',
      ...(init.headers as Record<string, string> || {}),
    },
  })
}

async function fetchPopulation(): Promise<Row[]> {
  // journal=is.null tar bara NULL — tom sträng får en OR-branch.
  const url = `articles?select=id,url,source,journal&irrelevant=not.is.true&or=(journal.is.null,journal.eq.)&limit=1000`
  const res = await sbFetch(url)
  if (!res.ok) throw new Error(`population fetch: HTTP ${res.status} ${(await res.text()).slice(0, 200)}`)
  return await res.json() as Row[]
}

// Extrahera DOI ur url. Samma normalize-mönster som daily-fetch:79-82 —
// stripa protokoll + doi.org-prefix, tolerera dx.doi.org.
function extractDoi(url: string | null | undefined): string | null {
  if (!url) return null
  const s = url.trim()
  const m = s.match(/(?:https?:\/\/)?(?:dx\.)?doi\.org\/(.+?)(?:[?#]|$)/i)
  if (m) return m[1].trim()
  // Ren DOI utan URL-prefix?
  if (/^10\.\d{4,}\/\S+$/.test(s)) return s
  return null
}

function extractOpenAlexId(url: string | null | undefined): string | null {
  if (!url) return null
  const m = url.match(/openalex\.org\/(W\d+)/i)
  return m ? m[1] : null
}

// Applicera samma fallback-kedja som daily-fetch:626-635 (ORDER 161-fixen).
function extractJournalFromOpenAlexWork(w: any): string {
  const primary = w?.primary_location?.source?.display_name
  if (typeof primary === 'string' && primary.trim().length > 0) return primary.trim()
  const locations = Array.isArray(w?.locations) ? w.locations : []
  for (const loc of locations) {
    const name = loc?.source?.display_name
    if (typeof name === 'string' && name.trim().length > 0) return name.trim()
  }
  return ''
}

async function openalexLookup(row: Row): Promise<
  | { ok: true, journal: string, via: 'openalex_id' | 'doi' }
  | { ok: false, reason: 'no_lookup_key' | 'no_journal_in_response' | 'http_error' | 'parse_error' }
> {
  // Prio 1: OpenAlex Work-ID (mest exakt, ingen ambiguitet)
  const oaId = extractOpenAlexId(row.url)
  // Prio 2: DOI (fungerar för alla sources så länge url innehåller doi.org)
  const doi = extractDoi(row.url)
  if (!oaId && !doi) return { ok: false, reason: 'no_lookup_key' }

  const key = oaId ? oaId : `doi:${doi}`
  const via: 'openalex_id' | 'doi' = oaId ? 'openalex_id' : 'doi'
  const url = `https://api.openalex.org/works/${encodeURIComponent(key)}?mailto=${encodeURIComponent(OPENALEX_MAILTO)}`

  let res: Response
  try {
    res = await fetch(url, { headers: { 'User-Agent': `GustoScience/1.0 (mailto:${OPENALEX_MAILTO})` } })
  } catch (_e) {
    return { ok: false, reason: 'http_error' }
  }
  if (!res.ok) return { ok: false, reason: 'http_error' }

  let work: any
  try { work = await res.json() } catch (_e) { return { ok: false, reason: 'parse_error' } }
  const journal = extractJournalFromOpenAlexWork(work)
  if (!journal) return { ok: false, reason: 'no_journal_in_response' }
  return { ok: true, journal, via }
}

async function writeJournal(id: string, journal: string): Promise<{ ok: true } | { ok: false, reason: string }> {
  const res = await sbFetch(`articles?id=eq.${id}`, {
    method: 'PATCH',
    headers: { 'Prefer': 'return=minimal' },
    body: JSON.stringify({ journal }),
  })
  if (!res.ok) return { ok: false, reason: `db ${res.status}: ${(await res.text()).slice(0, 200)}` }
  return { ok: true }
}

async function main() {
  console.log(`Fetching population (journal null/empty, irrelevant not true)...`)
  let population = await fetchPopulation()
  console.log(`  ${population.length} rader hittade`)

  if (limit > 0 && population.length > limit) {
    console.log(`  --limit ${limit}: bara första ${limit} raderna processas`)
    population = population.slice(0, limit)
  }

  // Fördelning per source (för rapportering)
  const sourceCount = new Map<string, number>()
  for (const r of population) {
    const s = r.source || '(null)'
    sourceCount.set(s, (sourceCount.get(s) ?? 0) + 1)
  }
  console.log(`\nSource-fördelning i populationen:`)
  for (const [s, n] of [...sourceCount.entries()].sort((a, b) => b[1] - a[1])) {
    console.log(`  ${s.padEnd(20)} ${n.toString().padStart(4)}`)
  }

  // Klassificera i förväg vilken lookup-strategi varje rad har
  let stratNoKey = 0, stratOaId = 0, stratDoi = 0
  for (const r of population) {
    if (extractOpenAlexId(r.url)) stratOaId++
    else if (extractDoi(r.url)) stratDoi++
    else stratNoKey++
  }
  console.log(`\nLookup-strategi:`)
  console.log(`  OpenAlex Work-ID (url matchar openalex.org/W…) : ${stratOaId}`)
  console.log(`  DOI (url matchar doi.org/…)                     : ${stratDoi}`)
  console.log(`  Ingen (skippas)                                  : ${stratNoKey}`)

  console.log(`\n${apply ? 'APPLY' : 'DRY-RUN'} — startar lookups (${REQ_DELAY_MS} ms delay per request)...`)
  const startedAt = Date.now()

  const results = {
    total: population.length,
    resolved: 0,          // journal hittad → skulle skrivas
    no_lookup_key: 0,     // varken openalex-id eller DOI i url
    no_journal_in_response: 0,   // OpenAlex-svar utan venue-namn även efter fallback-kedjan
    http_error: 0,
    parse_error: 0,
    written: 0,
    write_failed: 0,
  }
  const perSource = new Map<string, { resolved: number, no_key: number, no_journal: number, error: number }>()
  const bump = (s: string, k: keyof { resolved: number, no_key: number, no_journal: number, error: number }) => {
    const cur = perSource.get(s) ?? { resolved: 0, no_key: 0, no_journal: 0, error: 0 }
    cur[k] += 1
    perSource.set(s, cur)
  }

  // Loggar de första 20 lyckade lookups + första 10 misslyckade för
  // stichprovs-verifiering i dry-run.
  const samples: string[] = []

  for (let i = 0; i < population.length; i++) {
    const row = population[i]
    const src = row.source || '(null)'
    if (i > 0) await new Promise(r => setTimeout(r, REQ_DELAY_MS))

    const r = await openalexLookup(row)
    if (!r.ok) {
      results[r.reason] += 1
      if (r.reason === 'no_lookup_key') bump(src, 'no_key')
      else if (r.reason === 'no_journal_in_response') bump(src, 'no_journal')
      else bump(src, 'error')
      if (samples.filter(s => s.startsWith('FAIL')).length < 10) {
        samples.push(`FAIL [${row.id.slice(0, 8)}] ${src} ${r.reason} url=${(row.url || '').slice(0, 60)}`)
      }
      continue
    }
    results.resolved += 1
    bump(src, 'resolved')
    if (samples.filter(s => s.startsWith('OK')).length < 20) {
      samples.push(`OK   [${row.id.slice(0, 8)}] ${src} via=${r.via.padEnd(11)} journal="${r.journal.slice(0, 60)}"`)
    }

    if (apply) {
      const w = await writeJournal(row.id, r.journal)
      if (w.ok) results.written += 1
      else {
        results.write_failed += 1
        console.error(`  [${row.id.slice(0, 8)}] WRITE FAIL: ${w.reason}`)
      }
    }

    // Progress-log var 50:e rad
    if ((i + 1) % 50 === 0) {
      console.log(`  ...${i + 1}/${population.length} processade`)
    }
  }

  const elapsed = ((Date.now() - startedAt) / 1000).toFixed(1)
  console.log(`\n=== Backfill summary (${apply ? 'APPLY' : 'DRY-RUN'}) ===`)
  console.log(`Elapsed                        : ${elapsed} s`)
  console.log(`Total processed                : ${results.total}`)
  console.log(`  → journal resolved           : ${results.resolved}`)
  console.log(`  → no lookup key (skip)       : ${results.no_lookup_key}`)
  console.log(`  → OpenAlex svar utan venue   : ${results.no_journal_in_response}`)
  console.log(`  → HTTP-fel                   : ${results.http_error}`)
  console.log(`  → parse-fel                  : ${results.parse_error}`)
  if (apply) {
    console.log(`  → written to DB              : ${results.written}`)
    console.log(`  → write failed               : ${results.write_failed}`)
  }

  console.log(`\nPer source:`)
  for (const [s, c] of [...perSource.entries()].sort((a, b) => (b[1].resolved + b[1].no_key + b[1].no_journal + b[1].error) - (a[1].resolved + a[1].no_key + a[1].no_journal + a[1].error))) {
    console.log(`  ${s.padEnd(20)} resolved=${c.resolved} no_key=${c.no_key} no_journal=${c.no_journal} error=${c.error}`)
  }

  console.log(`\nSamples (first 20 OK + first 10 FAIL):`)
  for (const s of samples) console.log(`  ${s}`)

  if (!apply) {
    console.log(`\n[dry-run] Inga DB-skrivningar. Kör om med --apply för att skriva.`)
    console.log(`  Kräver att migration 20260825150000_journal_backup_pre_order_161.sql är applicerad först.`)
  }
}

if (import.meta.main) await main()
