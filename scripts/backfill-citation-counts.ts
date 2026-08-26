// scripts/backfill-citation-counts.ts
//
// ORDER 175 (2026-08-26) — citation_count-backfill + återkommande delta-uppdatering.
//
// KONTEXT
// -------
// 2026-08-26: 123 av 35 141 relevanta artiklar hade citation_count > 0
// (0,35 %). Ingen av de fyra ingest-källorna (OpenAlex, Scopus, PubMed, S2)
// skrev fältet — daily-fetch:s upsert-block saknade citation_count helt.
// ORDER 175 fixade framåt-flödet + denna backfill fångar det historiska.
//
// KÖRSLÄGE
// --------
//   default (dry-run)  — fetch citation_counts från OpenAlex, jämför mot DB,
//                        rapportera delta. Ingen skrivning.
//   --apply            — samma, men skriv delta via bulk_update_citation_counts
//                        RPC. Ingen heartbeat i dry-run.
//   --limit N          — bara första N rader (test)
//
// SCHEMALÄGGNING
// --------------
// Kör två gånger i veckan via GHA (måndag + torsdag 06:00 UTC) — se
// .github/workflows/citation-updates.yml. Heartbeat skrivs till
// public.citation_updates_runs; health-alert citations_stalled larmar om
// alder_h > 96 (4 dygn = missad Mon+Thu-slot + halv dag) OCH backlog > 5000.
//
// PRESTANDA
// ---------
// - OpenAlex bulk-endpoint: `/works?filter=openalex:W1|W2|...&per-page=100`
//   eller `filter=doi:D1|D2|...` — 100 rader per request. Polite pool = ~10
//   req/s (med mailto-header i URL). 35 000 rader = 350 requests = ~35-70s.
// - Delta-skrivning via bulk_update_citation_counts RPC — chunks om 5000
//   rader per anrop. Server-side WHERE citation_count IS DISTINCT FROM
//   skippar rader utan ändring (typiskt 95 % efter första körning).
//
// ANVÄNDNING
// ----------
//   # Dry-run mot hela populationen
//   deno run --allow-net --allow-env --allow-read \
//     scripts/backfill-citation-counts.ts
//
//   # Test-batch mot första 200 rader
//   deno run --allow-net --allow-env --allow-read \
//     scripts/backfill-citation-counts.ts --limit 200
//
//   # Apply — kör mot hela populationen och skriv delta
//   deno run --allow-net --allow-env --allow-read \
//     scripts/backfill-citation-counts.ts --apply
//
// MILJÖ
// -----
//   SUPABASE_URL              — default: prod-URL
//   SUPABASE_SERVICE_ROLE_KEY — krävs (RLS bypass + RPC-EXECUTE)
//   OPENALEX_MAILTO           — email för polite pool (rekommenderat)
//   GITHUB_RUN_ID             — sätts automatiskt av GHA; styr triggered_by

const SB_URL = Deno.env.get('SUPABASE_URL') || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
const OPENALEX_MAILTO = Deno.env.get('OPENALEX_MAILTO') || 'anders@crichton-fock.com'
const TRIGGERED_BY = Deno.env.get('GITHUB_RUN_ID') ? 'gha' : 'manual'

if (!SB_KEY) {
  console.error('SUPABASE_SERVICE_ROLE_KEY not set')
  Deno.exit(1)
}

const args = Deno.args
const APPLY = args.includes('--apply')
let LIMIT = 0
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--limit' && args[i + 1]) LIMIT = parseInt(args[i + 1]) || 0
}

const OPENALEX_BATCH = 100
const RPC_BATCH      = 5000
const REQ_DELAY_MS   = 120    // ~8 req/s, snällare än polite pool-tak

type Row = {
  id: string
  url: string | null
  citation_count: number | null
}

// ── Supabase helpers ──
function sbHeaders(): Record<string, string> {
  return {
    'apikey':        SB_KEY,
    'Authorization': `Bearer ${SB_KEY}`,
    'Content-Type':  'application/json',
  }
}

async function sbFetch(path: string, init: RequestInit = {}): Promise<Response> {
  return await fetch(`${SB_URL}/rest/v1/${path}`, {
    ...init,
    headers: { ...sbHeaders(), ...(init.headers as Record<string, string> || {}) },
  })
}

// Population — artiklar med lookup-nyckel (OpenAlex-ID eller DOI i url).
// url ~ 'openalex\.org/W\d+' ELLER url ilike '%doi.org%'. Läs i sidor om
// 1000 så vi inte fastnar på PostgREST-limit.
async function fetchPopulation(): Promise<Row[]> {
  const all: Row[] = []
  const pageSize = 1000
  let offset = 0
  while (true) {
    const url = `articles?select=id,url,citation_count&irrelevant=not.is.true`
              + `&or=(url.match.openalex\\.org%2FW,url.ilike.%25doi.org%25)`
              + `&order=id&limit=${pageSize}&offset=${offset}`
    const res = await sbFetch(url)
    if (!res.ok) throw new Error(`population fetch: HTTP ${res.status} ${(await res.text()).slice(0, 200)}`)
    const page = await res.json() as Row[]
    all.push(...page)
    if (page.length < pageSize) break
    offset += pageSize
    if (LIMIT > 0 && all.length >= LIMIT) break
  }
  return LIMIT > 0 ? all.slice(0, LIMIT) : all
}

async function bulkUpdate(payload: {id: string, c: number}[]): Promise<number> {
  const res = await sbFetch(`rpc/bulk_update_citation_counts`, {
    method: 'POST',
    body: JSON.stringify({ payload }),
  })
  if (!res.ok) {
    throw new Error(`bulk_update RPC: HTTP ${res.status} ${(await res.text()).slice(0, 300)}`)
  }
  const n = await res.json() as number
  return typeof n === 'number' ? n : 0
}

// ── Heartbeat (samma mönster som ORDER 148 send-weekly-digest) ──
async function heartbeatStart(): Promise<number | null> {
  if (!APPLY) return null
  try {
    const res = await sbFetch(`citation_updates_runs`, {
      method:  'POST',
      headers: { 'Prefer': 'return=representation' },
      body:    JSON.stringify({ triggered_by: TRIGGERED_BY }),
    })
    if (!res.ok) {
      console.log('[heartbeat] start INSERT failed:', res.status, (await res.text()).slice(0, 200))
      return null
    }
    const rows = await res.json()
    return rows?.[0]?.id ?? null
  } catch (e) {
    console.log('[heartbeat] start threw:', (e as Error).message)
    return null
  }
}

async function heartbeatUpdate(runId: number | null, patch: Record<string, unknown>): Promise<void> {
  if (!APPLY || runId === null) return
  try {
    const res = await sbFetch(`citation_updates_runs?id=eq.${runId}`, {
      method: 'PATCH',
      body:   JSON.stringify(patch),
    })
    if (!res.ok) console.log('[heartbeat] PATCH failed:', res.status, (await res.text()).slice(0, 200))
  } catch (e) {
    console.log('[heartbeat] PATCH threw:', (e as Error).message)
  }
}

// ── URL-parsning ──
function extractOpenAlexId(url: string | null | undefined): string | null {
  if (!url) return null
  const m = url.match(/openalex\.org\/(W\d+)/i)
  return m ? m[1] : null
}

function extractDoi(url: string | null | undefined): string | null {
  if (!url) return null
  const m = url.trim().match(/(?:https?:\/\/)?(?:dx\.)?doi\.org\/(.+?)(?:[?#]|$)/i)
  return m ? m[1].trim() : null
}

// ── OpenAlex bulk-fetch ──
// Endpoint: /works?filter=openalex:W1|W2|... eller filter=doi:D1|D2|...
// Retur: {results: [{id: "https://openalex.org/W...", cited_by_count: N}, ...]}
// Fältet cited_by_count är top-level integer, alltid present.
type FetchOk   = { ok: true,  citation_count: number }
type FetchFail = { ok: false, reason: string }

async function fetchOpenAlexBulk(
  keyType: 'openalex' | 'doi',
  keys: string[],
): Promise<Map<string, FetchOk | FetchFail>> {
  const map = new Map<string, FetchOk | FetchFail>()
  if (keys.length === 0) return map

  // Bygg filter-parametern
  const filterVal = keys.join('|')
  const url = `https://api.openalex.org/works?filter=${keyType}:${encodeURIComponent(filterVal)}`
            + `&per-page=100&mailto=${encodeURIComponent(OPENALEX_MAILTO)}`
            + `&select=id,doi,cited_by_count`

  let res: Response
  try {
    res = await fetch(url, {
      headers: { 'User-Agent': `GustoScience/1.0 (mailto:${OPENALEX_MAILTO})` },
    })
  } catch (_e) {
    for (const k of keys) map.set(k, { ok: false, reason: 'network_error' })
    return map
  }

  if (!res.ok) {
    const errText = `http_${res.status}`
    for (const k of keys) map.set(k, { ok: false, reason: errText })
    return map
  }

  let json: any
  try { json = await res.json() } catch (_e) {
    for (const k of keys) map.set(k, { ok: false, reason: 'parse_error' })
    return map
  }

  const results = Array.isArray(json?.results) ? json.results : []

  // Matchning: results returnerar full URL i "id" ("https://openalex.org/W123")
  // och "doi" ("https://doi.org/10.xxx/..."). Vi behöver plocka ut jämförelse-
  // nyckeln i samma form som våra keys-in.
  for (const w of results) {
    const cc = typeof w?.cited_by_count === 'number' ? w.cited_by_count : 0
    if (keyType === 'openalex') {
      const wId = String(w?.id || '').replace(/^https?:\/\/openalex\.org\//i, '')
      if (wId) map.set(wId, { ok: true, citation_count: cc })
    } else {
      // DOI från OpenAlex kan innehålla https://doi.org/ prefix
      const wDoi = String(w?.doi || '').replace(/^https?:\/\/(?:dx\.)?doi\.org\//i, '')
      if (wDoi) map.set(wDoi, { ok: true, citation_count: cc })
    }
  }

  // Fyll i "not_found" för keys som inte kom tillbaka
  for (const k of keys) {
    if (!map.has(k)) map.set(k, { ok: false, reason: 'not_found' })
  }
  return map
}

// ── Main ──
async function main() {
  const startedAt = new Date().toISOString()
  console.log(`[start] mode=${APPLY ? 'APPLY (skriver)' : 'DRY-RUN'}  at=${startedAt}  trigger=${TRIGGERED_BY}`)

  const runId = await heartbeatStart()
  if (runId !== null) console.log(`[heartbeat] citation_updates_runs.id = ${runId}`)

  console.log(`[population] hämtar articles med lookup-nyckel...`)
  const population = await fetchPopulation()
  console.log(`  ${population.length.toLocaleString()} rader (${LIMIT > 0 ? `limit ${LIMIT}` : 'full korpus'})`)

  // Klassificera per lookup-strategi
  const byOaId: {row: Row, key: string}[] = []
  const byDoi:  {row: Row, key: string}[] = []
  let noKey = 0
  for (const row of population) {
    const oa = extractOpenAlexId(row.url)
    if (oa) { byOaId.push({ row, key: oa }); continue }
    const doi = extractDoi(row.url)
    if (doi) { byDoi.push({ row, key: doi }); continue }
    noKey++
  }
  console.log(`  OpenAlex Work-ID   : ${byOaId.length.toLocaleString()}`)
  console.log(`  DOI                : ${byDoi.length.toLocaleString()}`)
  console.log(`  ingen nyckel (skip): ${noKey.toLocaleString()}`)

  const results = {
    checked:     0,   // fetch:ade från OpenAlex
    delta:       0,   // rader där hämtat värde skiljer sig från DB
    not_found:   0,   // OpenAlex kände inte igen id/doi
    api_errors:  0,   // network / http_5xx / parse
    written:     0,   // faktiskt skrivna (från bulk_update-RPC)
  }

  // Bearbeta i två pass — en per lookup-typ
  const passes: {kind: 'openalex' | 'doi', items: {row: Row, key: string}[]}[] = [
    { kind: 'openalex', items: byOaId },
    { kind: 'doi',      items: byDoi  },
  ]

  const pendingWrites: {id: string, c: number}[] = []

  for (const pass of passes) {
    console.log(`\n[fetch] ${pass.kind} — ${pass.items.length.toLocaleString()} rader`)
    for (let i = 0; i < pass.items.length; i += OPENALEX_BATCH) {
      const chunk = pass.items.slice(i, i + OPENALEX_BATCH)
      const keys  = chunk.map(x => x.key)
      const map   = await fetchOpenAlexBulk(pass.kind, keys)
      results.checked += chunk.length
      for (const {row, key} of chunk) {
        const r = map.get(key)
        if (!r) { results.api_errors++; continue }
        if (!r.ok) {
          if (r.reason === 'not_found') results.not_found++
          else                          results.api_errors++
          continue
        }
        // Delta-check client-side (även om RPC:n gör om det server-side —
        // spar RPC-payload-bytes i typfallet där ~95 % inte ändrats).
        const existing = row.citation_count ?? null
        if (existing !== r.citation_count) {
          results.delta++
          pendingWrites.push({ id: row.id, c: r.citation_count })
        }
      }
      if ((i / OPENALEX_BATCH) % 10 === 0 && i > 0) {
        console.log(`  ...${(i + chunk.length).toLocaleString()}/${pass.items.length.toLocaleString()} — delta=${results.delta}, not_found=${results.not_found}, errors=${results.api_errors}`)
      }
      // Rate-limit mellan bulk-anrop
      await new Promise(r => setTimeout(r, REQ_DELAY_MS))
    }
  }

  console.log(`\n[fetch klar] checked=${results.checked.toLocaleString()}, delta=${results.delta.toLocaleString()}, not_found=${results.not_found.toLocaleString()}, errors=${results.api_errors.toLocaleString()}`)

  // Skrivning
  if (APPLY && pendingWrites.length > 0) {
    console.log(`\n[write] skriver ${pendingWrites.length.toLocaleString()} rader via bulk_update_citation_counts (chunks om ${RPC_BATCH})...`)
    let writeErrors = 0
    for (let i = 0; i < pendingWrites.length; i += RPC_BATCH) {
      const chunk = pendingWrites.slice(i, i + RPC_BATCH)
      try {
        const written = await bulkUpdate(chunk)
        results.written += written
        console.log(`  chunk ${(i / RPC_BATCH) + 1}: sent=${chunk.length}, updated=${written}`)
      } catch (e) {
        writeErrors++
        console.error(`  chunk ${(i / RPC_BATCH) + 1}: FAIL — ${(e as Error).message}`)
      }
    }
    if (writeErrors > 0) results.api_errors += writeErrors
  } else if (!APPLY) {
    console.log(`\n[dry-run] hoppar skrivning. Kör om med --apply.`)
  }

  const finishedAt = new Date().toISOString()
  const elapsed = ((Date.now() - Date.parse(startedAt)) / 1000).toFixed(1)
  console.log(`\n=== Summary (${APPLY ? 'APPLY' : 'DRY-RUN'}) ===`)
  console.log(`Elapsed          : ${elapsed} s`)
  console.log(`Articles checked : ${results.checked.toLocaleString()}`)
  console.log(`Delta detected   : ${results.delta.toLocaleString()}`)
  console.log(`Not found        : ${results.not_found.toLocaleString()}`)
  console.log(`API errors       : ${results.api_errors.toLocaleString()}`)
  if (APPLY) console.log(`Rows updated     : ${results.written.toLocaleString()}`)

  await heartbeatUpdate(runId, {
    finished_at:      finishedAt,
    articles_checked: results.checked,
    articles_updated: results.written,
    api_errors:       results.api_errors,
  })
}

// ORDER 148-mönster: catch fatal + skriv till heartbeat innan exit.
main().catch(async (e) => {
  console.error('[FATAL]', e)
  if (APPLY) {
    try {
      const r = await sbFetch(`citation_updates_runs?finished_at=is.null&order=id.desc&limit=1`)
      const rows = r.ok ? await r.json() : []
      const openRow = rows?.[0]
      if (openRow?.id) {
        await sbFetch(`citation_updates_runs?id=eq.${openRow.id}`, {
          method: 'PATCH',
          body:   JSON.stringify({
            finished_at: new Date().toISOString(),
            fatal_error: String((e as Error).message || e).slice(0, 500),
          }),
        })
      }
    } catch (_) { /* swallow — vi håller på att exit:a med felkod */ }
  }
  Deno.exit(1)
})
