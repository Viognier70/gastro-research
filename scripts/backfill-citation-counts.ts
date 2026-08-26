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
//   # Återuppta efter kvot-slut — hoppa över alla rader med id ≤ <uuid>
//   # vid fetchPopulation-steget. Läs "sista id" från förra körningens
//   # progress-logg och kör vidare därifrån.
//   deno run --allow-net --allow-env --allow-read \
//     scripts/backfill-citation-counts.ts --apply --since-id <uuid>
//
// OPENALEX-KVOT (2026-08-26)
// --------------------------
// Polite pool har ~100 000 requests/dag per mailto. En full körning =
// ~350 requests (~35 000 rader ÷ 100 per batch), så GHA-schemat 2×/vecka
// har rejäl marginal. VARNING: manuella omkörningar under utveckling
// har spräckt dygnskvoten (3 fulla körningar på en timme = kvot-slut med
// Retry-After 51 835 s ≈ 14 h). Skriptet abort:ar nu vid Retry-After
// > 300 s istället för att sova ut väntetiden. Testa mot --limit N eller
// --since-id-delmängd innan full körning under utveckling.
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
let SINCE_ID = ''
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--limit'    && args[i + 1]) LIMIT    = parseInt(args[i + 1]) || 0
  if (args[i] === '--since-id' && args[i + 1]) SINCE_ID = args[i + 1]
}

const OPENALEX_BATCH = 100
const RPC_BATCH      = 5000
const REQ_DELAY_MS   = 120    // ~8 req/s, snällare än polite pool-tak

// ByYear-typen definieras tidigare än fetchOpenAlexBulk-blocket för att
// Row ska kunna referera den (ORDER 176 fix 2026-08-26 — hasDelta måste
// jämföra citations_by_year, inte bara count).
type ByYear = Array<{year: number, cited_by_count: number}>

type Row = {
  id: string
  url: string | null
  citation_count: number | null
  citations_by_year: ByYear | null
}

// Kanonisk sträng-representation för orderkänslig jämförelse mellan
// pre-existing DB-värde och nyhämtad OpenAlex-payload. Sorterar på year
// ASC + filtrerar felaktiga entries. Tom array → '' (samma som null).
function byYearKey(x: unknown): string {
  if (!Array.isArray(x)) return ''
  const norm = x
    .filter((e: any) => typeof e?.year === 'number' && typeof e?.cited_by_count === 'number')
    .map((e: any) => ({ year: e.year, cited_by_count: e.cited_by_count }))
    .sort((a, b) => a.year - b.year)
  return norm.map(e => `${e.year}:${e.cited_by_count}`).join(',')
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
// url ~ 'openalex\.org/W\d+' ELLER url ilike '%doi.org%'.
//
// KEYSET-paginering (fix 2026-08-26). Tidigare OFFSET-baserad variant tippade
// över statement_timeout (code 57014): OR-filtret använder regex/ilike på url
// som inte kan slå på index, så Postgres tvingades filtrera hela 466k-korpusen
// + sortera + skippa <offset> rader per request. Kvadratiskt beteende ju
// djupare — och redan första sidan tickade timeout på prod.
//
// Keyset använder PK-indexet på id för att skanna framåt konstant tid:
// WHERE id > <lastId>, ORDER BY id ASC. Postgres skummar id-index framåt och
// applicerar OR-filtret per rad, stannar efter <pageSize> träffar. Ingen
// full-tabell-filter, ingen OFFSET-hopp. Chunk-tid är O(pageSize / matchrate).
//
// count=exact körs BARA på första requesten (behövs för progress-loggen);
// efterföljande requests skippar den — sparar N × redundant COUNT.
async function fetchPopulation(): Promise<Row[]> {
  const all: Row[] = []
  const pageSize = 1000
  // ORDER 176 fix (2026-08-26): --since-id-återupptagning. lastId startar
  // som SINCE_ID (om satt) → första fetch:en använder id > SINCE_ID som
  // keyset-filter → rader med id ≤ SINCE_ID hoppas över helt vid DB-nivå.
  let lastId: string | null = SINCE_ID || null
  let total: number | null = null

  while (true) {
    const isFirst = total === null
    const keyFilter = lastId ? `&id=gt.${lastId}` : ''
    const url = `articles?select=id,url,citation_count,citations_by_year&irrelevant=not.is.true`
              + `&or=(url.match.openalex\\.org%2FW,url.ilike.%25doi.org%25)`
              + `${keyFilter}&order=id.asc&limit=${pageSize}`
    const headers: Record<string, string> = {}
    if (isFirst) headers['Prefer'] = 'count=exact'

    const res = await sbFetch(url, { headers })
    if (!res.ok && res.status !== 206) {
      throw new Error(`population fetch: HTTP ${res.status} ${(await res.text()).slice(0, 200)}`)
    }
    if (isFirst) {
      const range = res.headers.get('content-range') || ''
      total = parseInt(range.split('/')[1] || '0', 10)
    }
    const page = await res.json() as Row[]
    all.push(...page)
    const lastInPage = page.length > 0 ? page[page.length - 1].id : lastId
    console.log(`  ...hämtat ${all.length.toLocaleString()}/${total ?? '?'} — sista id: ${lastInPage}`)
    if (page.length < pageSize) break
    lastId = page[page.length - 1].id
    if (LIMIT > 0 && all.length >= LIMIT) break
  }
  return LIMIT > 0 ? all.slice(0, LIMIT) : all
}

// ORDER 176 (2026-08-26): RPC v2 accepterar valfritt by_year per rad +
// p_run_id. by_year skrivs till articles.citations_by_year, delta-rad
// skrivs till citation_deltas när p_run_id är satt. bulks utan runId
// (t.ex. dry-run från terminal) skriver ingen delta-post — RPC-sidan
// hanterar den grinden.
async function bulkUpdate(
  payload: {id: string, c: number, by_year?: unknown}[],
  runId: number | null,
): Promise<number> {
  const body: Record<string, unknown> = { payload }
  if (runId !== null) body.p_run_id = runId
  const res = await sbFetch(`rpc/bulk_update_citation_counts`, {
    method: 'POST',
    body: JSON.stringify(body),
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
// Retur: {results: [{id, cited_by_count, counts_by_year: [{year, cited_by_count}, ...]}, ...]}
// cited_by_count är top-level integer (alltid present).
// counts_by_year är array (typiskt 5-10 år), null/[] för verk utan citeringar.
// (ByYear-typen är deklarerad högre upp så Row kan referera den.)
type FetchOk   = { ok: true,  citation_count: number, by_year: ByYear | null }
type FetchFail = { ok: false, reason: string }

// ORDER 176 fix (2026-08-26): retry-wrapper mot 429/503 + nätverksfel.
// Tidigare räknades varje 429 som permanent api_error → 5 463 fel från
// batch ~20 000 och framåt vid full-körning. OpenAlex skickar Retry-After
// i sekunder — honorera den, fall tillbaka på 30 s för rate-limit och
// 5 s för övriga transienta fel.
//
// TAK PÅ VÄNTETID (2026-08-26 fix efter kvot-slut-incident): Retry-After
// > 300 s är per definition en dygnskvot-reset (uppmätt 51 835 s ≈ 14 h),
// inte en burst-strypning. Skriptet abort:ar då hellre än att sova ut
// väntan — dev startar om med --since-id efter kvoten återställts.
const MAX_RETRY          = 3
const MAX_RETRY_WAIT_SEC = 300

class QuotaExhaustedError extends Error {
  constructor(waitSec: number, lastId: string | null) {
    const hint = lastId ? ` --since-id ${lastId}` : ''
    super(
      `OpenAlex-kvot slut: Retry-After ${waitSec}s ≈ ${(waitSec / 3600).toFixed(1)}h. ` +
      `Överskrider MAX_RETRY_WAIT_SEC=${MAX_RETRY_WAIT_SEC}s. ` +
      `Vänta tills kvoten återställs, kör sedan om med:${hint}`
    )
    this.name = 'QuotaExhaustedError'
  }
}

// Referens till senaste bearbetade article-id — uppdateras i main:s
// fetch-loop så QuotaExhaustedError-meddelandet kan förslå --since-id.
let lastProcessedId: string | null = null

async function fetchWithRetry(url: string, headers: Record<string, string>): Promise<Response | null> {
  for (let attempt = 1; attempt <= MAX_RETRY; attempt++) {
    let res: Response
    try {
      res = await fetch(url, { headers })
    } catch (_e) {
      if (attempt === MAX_RETRY) return null
      const wait = 5 * attempt
      console.log(`  [network] fetch kastade (försök ${attempt}/${MAX_RETRY}) — retry om ${wait}s`)
      await new Promise(r => setTimeout(r, wait * 1000))
      continue
    }
    // Transienta HTTP-fel som är värda retry. Kastar utanför fetch-try/catch
    // så QuotaExhaustedError-throwet inte fångas av nätverks-handlaren.
    if (res.status === 429 || res.status === 503) {
      const ra = parseInt(res.headers.get('retry-after') || '', 10)
      const wait = Number.isFinite(ra) && ra > 0 ? ra : 30 * attempt
      if (wait > MAX_RETRY_WAIT_SEC) {
        throw new QuotaExhaustedError(wait, lastProcessedId)
      }
      if (attempt === MAX_RETRY) return res
      console.log(`  [rate-limit] HTTP ${res.status}, Retry-After ${wait}s (försök ${attempt}/${MAX_RETRY})`)
      await new Promise(r => setTimeout(r, wait * 1000))
      continue
    }
    return res
  }
  return null
}

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
            + `&select=id,doi,cited_by_count,counts_by_year`

  const res = await fetchWithRetry(url, {
    'User-Agent': `GustoScience/1.0 (mailto:${OPENALEX_MAILTO})`,
  })
  if (res === null) {
    // 3 nätverksfel i rad → ge upp, markera batchen som fel.
    for (const k of keys) map.set(k, { ok: false, reason: 'network_error' })
    return map
  }
  if (!res.ok) {
    // Resterande HTTP-fel efter retry (t.ex. 429 efter 3 väntor, eller 4xx
    // som inte är transient) räknas som permanent för batchen.
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
    // counts_by_year kan vara array, null, eller saknas. Filtrera till bara
    // rader med både year + cited_by_count som numbers — försvar mot ev.
    // felaktiga entries från OpenAlex (sett i praktiken vid API-glitchar).
    // Sortera på year ASC — Postgres jsonb-array equality kräver samma
    // element-ordning och OpenAlex garanterar inte sort-riktning. Sortering
    // client-side gör server-side citations_by_year IS DISTINCT FROM stabil.
    const rawBy = Array.isArray(w?.counts_by_year) ? w.counts_by_year : []
    const by: ByYear = rawBy
      .filter((x: any) => typeof x?.year === 'number' && typeof x?.cited_by_count === 'number')
      .map((x: any) => ({ year: x.year, cited_by_count: x.cited_by_count }))
      .sort((a, b) => a.year - b.year)
    const byOrNull = by.length > 0 ? by : null

    if (keyType === 'openalex') {
      const wId = String(w?.id || '').replace(/^https?:\/\/openalex\.org\//i, '')
      if (wId) map.set(wId, { ok: true, citation_count: cc, by_year: byOrNull })
    } else {
      // DOI från OpenAlex kan innehålla https://doi.org/ prefix
      const wDoi = String(w?.doi || '').replace(/^https?:\/\/(?:dx\.)?doi\.org\//i, '')
      if (wDoi) map.set(wDoi, { ok: true, citation_count: cc, by_year: byOrNull })
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
  if (SINCE_ID) console.log(`[resume] fetchPopulation hoppar över id ≤ ${SINCE_ID}`)

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

  const pendingWrites: {id: string, c: number, by_year?: ByYear | null}[] = []

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
        // Delta-check client-side. v2 jämförde bara citation_count — fel
        // eftersom citations_by_year var NULL för hela korpusen men aldrig
        // skrevs när count redan var korrekt sedan förra körningen (bug
        // rapporterad ORDER 176 fix 2026-08-26: Rows updated: 0 varje run).
        // v3 utökar villkoret: skriv också när by_year är NULL i DB eller
        // skiljer sig från OpenAlex-svar (byYearKey normaliserar båda sidor).
        const countChanged  = row.citation_count !== r.citation_count
        const byYearChanged = byYearKey(row.citations_by_year) !== byYearKey(r.by_year)
        if (countChanged || byYearChanged) {
          results.delta++
          pendingWrites.push({ id: row.id, c: r.citation_count, by_year: r.by_year })
        }
      }
      // Uppdatera resume-cursor efter varje batch. Ordningen är monoton
      // per pass eftersom fetchPopulation ger id-asc och pass-listorna
      // bygger i samma ordning. Två pass efter varandra (openalex → doi)
      // → cursor från byOaId kan vara högre än början på byDoi; --since-id
      // vid återstart är en KOARSE mekanism, vissa rader kan komma att
      // göras om. Idempotent på server-sidan (WHERE IS DISTINCT FROM), så
      // extra jobb kostar bara OpenAlex-kvot, inga dubbla skrivningar.
      lastProcessedId = chunk[chunk.length - 1].row.id
      if ((i / OPENALEX_BATCH) % 10 === 0 && i > 0) {
        console.log(`  ...${(i + chunk.length).toLocaleString()}/${pass.items.length.toLocaleString()} — sista id: ${lastProcessedId} — delta=${results.delta}, not_found=${results.not_found}, errors=${results.api_errors}`)
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
        const written = await bulkUpdate(chunk, runId)
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
  // Kvot-slut är förväntat vid utvecklings-omkörningar — särskilj det från
  // äkta katastrof så meddelandet syns utan att drunkna i stack-trace.
  if (e instanceof QuotaExhaustedError) {
    console.error(`\n[ABORT] ${e.message}\n`)
  } else {
    console.error('[FATAL]', e)
  }
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
