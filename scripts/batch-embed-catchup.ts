// batch-embed-catchup.ts
// ────────────────────────────────────────────────────────────────────────────
// Engångsscript: dra embedding-kön till 0 snabbare än den halvtimme-cron
// (generate-embeddings, */30 * * * *) hinner. Efter en batch-regen-triad-
// körning växer embedding-kön med tiotusen rader; cronens 300/tick × 48/dygn
// = 14 400/dygn räcker inte utan väntan i ~1 dygn. Detta script kör samma
// text-byggnad + OpenAI-anrop + DB-write som edge-fn:en, men synkront i
// följd tills kön är tom. 12k rader → ~5–10 min i stället för ~21h.
//
// KRITISKT: håller SAMMA text-invariant som edge-fn:en (title + core_claim +
// topic + 5 episteme, join med space, slice 8000) så embeddings är
// utbytbara med de cronen skriver. Om edge-fn:en ändrar text-format:
// uppdatera detta script i samma commit — annars driftar semantic-search
// mellan två embedding-generationer.
//
// ── FLÖDE ────────────────────────────────────────────────────────────────
// 1. Hämta alla IDs+text-fält från kön (embedding IS NULL AND
//    episteme_sensory_pro IS NOT NULL) via service_role.
// 2. Chunka i CHUNK-storlek (default 300 — samma som edge-fn:ens
//    DEFAULT_BATCH, säker mot 300k-tokens/anrop-caps).
// 3. Bygg texts[] per chunk, anropa OpenAI /v1/embeddings.
// 4. Skriv {embedding} per rad till DB (PATCH, parallellism 20).
// 5. Rapportera: ok, openai_error, db_error. Errored IDs → /tmp/-fil.
//
// ── ANVÄNDNING ────────────────────────────────────────────────────────────
// Torrkörning (räknar kön + estimerar kostnad, ingen OpenAI-request):
//   deno run --allow-net --allow-env \
//     scripts/batch-embed-catchup.ts --dry-run
//
// Kör hela kön:
//   deno run --allow-net --allow-env --allow-write \
//     scripts/batch-embed-catchup.ts
//
// Kör bara N rader (t.ex. sanity-test):
//   deno run --allow-net --allow-env --allow-write \
//     scripts/batch-embed-catchup.ts --limit 300
//
// ── MILJÖ ─────────────────────────────────────────────────────────────────
// OPENAI_API_KEY          — OpenAI-nyckel (samma som edge-fn:en)
// SUPABASE_URL            — https://igmkzhdovyhbfgjomrsc.supabase.co
// SUPABASE_SERVICE_ROLE_KEY — service_role för RLS-bypass (läs+skriv articles)
// ────────────────────────────────────────────────────────────────────────────

import {
  buildEmbeddingText,
  EMBEDDING_COLUMNS,
  type EmbeddingSource,
} from '../supabase/functions/_shared/embedding-text.ts'

// ── Konfiguration ────────────────────────────────────────────────────────────
const OPENAI_KEY = Deno.env.get('OPENAI_API_KEY') || ''
const SB_URL     = Deno.env.get('SUPABASE_URL')   || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_KEY     = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''

const MODEL       = 'text-embedding-3-small'   // MÅSTE matcha edge-fn:ens modell
const CHUNK       = 300                         // rader per OpenAI-anrop (edge-fn:ens DEFAULT_BATCH). 300 × ~600 tok (stickprovsmätning 2026-07-24: avg 2 386 tecken/artikel för title+core_claim+topic+5 episteme) = ~180k tokens, säker mot HARD_TOKENS=275k och OpenAI 300k-cap.
const HARD_TOKENS = 275_000                     // pack-tak per OpenAI-anrop (edge-fn:ens värde)
const DB_CONCURRENCY = 20                        // parallella per-rad-updates (edge-fn:ens värde)
const SB_PAGE     = 1000                        // rader per SELECT-page mot PostgREST
const MAX_RETRIES = 5                            // 429/5xx-backoff (exponentiell, respekterar Retry-After)

// OpenAI pricing 2025 (uppdatera om det ändras):
const PRICE_USD_PER_MTOKEN = 0.02

// ── Args ─────────────────────────────────────────────────────────────────────
type Args = { limit?: number, dryRun: boolean }
function parseArgs(): Args {
  const a: Args = { dryRun: false }
  const argv = Deno.args
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--limit')        a.limit = parseInt(argv[++i], 10)
    else if (argv[i] === '--dry-run') a.dryRun = true
    else { console.error(`Unknown arg: ${argv[i]}`); Deno.exit(2) }
  }
  if (a.limit !== undefined && (!Number.isFinite(a.limit) || a.limit <= 0)) {
    console.error('--limit måste vara positivt heltal')
    Deno.exit(2)
  }
  return a
}

// ── Utils ────────────────────────────────────────────────────────────────────
function requireEnv() {
  const missing: string[] = []
  if (!OPENAI_KEY) missing.push('OPENAI_API_KEY')
  if (!SB_KEY)     missing.push('SUPABASE_SERVICE_ROLE_KEY')
  if (missing.length) {
    console.error(`Missing env: ${missing.join(', ')}`)
    Deno.exit(2)
  }
}

async function sbFetch(path: string, init: RequestInit = {}): Promise<Response> {
  const headers = {
    'apikey': SB_KEY,
    'Authorization': `Bearer ${SB_KEY}`,
    'Content-Type': 'application/json',
    ...(init.headers as Record<string, string> || {}),
  }
  return await fetch(`${SB_URL}/rest/v1/${path}`, { ...init, headers })
}

// ── Text-invariant ───────────────────────────────────────────────────────────
// Delas med edge-fn:en via _shared/embedding-text.ts. INGEN lokal kopia här
// — refaktoreringen 2026-07-24 verifierades byte-identisk mot legacy inline
// på 200 slumpade artiklar (scripts/verify-embedding-text-refactor.ts).
type Article = EmbeddingSource & { id: string }

const est = (s: string) => Math.ceil(s.length / 4)

// ── Steg 1: hämta hela kön ───────────────────────────────────────────────────
async function fetchQueue(limit?: number): Promise<Article[]> {
  const cols = EMBEDDING_COLUMNS.join(',')
  const filter = 'episteme_sensory_pro=not.is.null&embedding=is.null'
  const out: Article[] = []
  let offset = 0
  while (true) {
    const page = Math.min(SB_PAGE, (limit ?? Infinity) - out.length)
    if (page <= 0) break
    const res = await sbFetch(
      `articles?select=${cols}&${filter}&order=id.asc&limit=${page}&offset=${offset}`
    )
    if (!res.ok) {
      console.error(`Fetch queue failed: HTTP ${res.status} ${await res.text().catch(() => '')}`)
      Deno.exit(3)
    }
    const rows = await res.json() as Article[]
    out.push(...rows)
    console.log(`  Fetched ${out.length}${limit ? `/${limit}` : ''}`)
    if (rows.length < page) break   // sista sidan
    offset += rows.length
  }
  return out
}

// ── Steg 2: kostnadsestimering ───────────────────────────────────────────────
function estimateCost(articles: Article[]): { tokens: number, usd: number } {
  let tokens = 0
  for (const a of articles) tokens += est(buildEmbeddingText(a))
  return { tokens, usd: (tokens / 1_000_000) * PRICE_USD_PER_MTOKEN }
}

// ── Steg 3: OpenAI-anrop ─────────────────────────────────────────────────────
type EmbeddingResp = { data: Array<{ index: number, embedding: number[] }> }

async function embedChunk(articles: Article[]): Promise<{
  ok: true, embeddings: Map<string, number[]>
} | {
  ok: false, error: string, status?: number
}> {
  // Pack tills HARD_TOKENS — samma logik som edge-fn:en, defensivt. Med
  // CHUNK=300 och stickprovsmätning 2026-07-24 (avg ~600 tokens/artikel) ryms
  // alla 300 rader (~180k tok) väl under HARD_TOKENS=275k. Om enskild artikel
  // är onormalt lång och taket smäller: deferrade rader stannar i kön till
  // nästa körning (SELECT plockar dem eftersom embedding fortfarande IS NULL).
  const texts: string[] = []
  const packedIds: string[] = []
  let sum = 0
  for (const a of articles) {
    const t = buildEmbeddingText(a)
    if (sum + est(t) > HARD_TOKENS) break
    texts.push(t)
    packedIds.push(a.id)
    sum += est(t)
  }
  if (!texts.length) return { ok: false, error: 'first article > HARD_TOKENS (should be impossible with TEXT_SLICE=8000)' }

  // Retry-loop med exponentiell backoff för 429 och 5xx. Respekterar
  // Retry-After-header (sekunder eller HTTP-datum) när den finns. Övriga
  // fel (4xx utom 429, timeout, nätverksfel) misslyckas direkt utan retry.
  let lastError = ''
  let lastStatus: number | undefined
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    if (attempt > 0) {
      const backoffMs = await computeBackoff(attempt, lastStatus, lastRetryAfter)
      await new Promise(r => setTimeout(r, backoffMs))
    }

    const ac = new AbortController()
    const timer = setTimeout(() => ac.abort(), 60_000)
    let res: Response
    try {
      res = await fetch('https://api.openai.com/v1/embeddings', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${OPENAI_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ model: MODEL, input: texts }),
        signal: ac.signal,
      })
    } catch (e) {
      clearTimeout(timer)
      const aborted = (e as Error).name === 'AbortError'
      lastError = aborted ? 'openai timeout after 60s' : (e as Error).message
      lastStatus = undefined
      lastRetryAfter = null
      // Timeout och nätverksfel: retry, andra runtime-fel: ge upp direkt.
      if (aborted || (e as Error).name === 'TypeError') continue
      return { ok: false, error: lastError }
    }
    clearTimeout(timer)

    if (res.ok) {
      const body = await res.json() as EmbeddingResp
      const arr = body.data || []
      if (arr.length !== texts.length) {
        return { ok: false, error: `openai returned ${arr.length} embeddings for ${texts.length} inputs` }
      }
      const map = new Map<string, number[]>()
      for (let i = 0; i < texts.length; i++) {
        const e = arr.find(x => x.index === i) ?? arr[i]
        if (!e || !Array.isArray(e.embedding)) {
          return { ok: false, error: `missing embedding for index ${i}` }
        }
        map.set(packedIds[i], e.embedding)
      }
      return { ok: true, embeddings: map }
    }

    // Icke-OK: extrahera error-body + Retry-After
    const errBody = (await res.text()).slice(0, 300)
    lastError = `openai ${res.status}: ${errBody}`
    lastStatus = res.status
    lastRetryAfter = parseRetryAfter(res.headers.get('retry-after'))

    // Retry bara på 429 och 5xx. 4xx utom 429 = deterministiskt fel, ge upp.
    if (res.status !== 429 && res.status < 500) {
      return { ok: false, error: lastError, status: res.status }
    }
  }
  return { ok: false, error: `${lastError} (after ${MAX_RETRIES} retries)`, status: lastStatus }
}

// Mellan-attempt-state för retry-backoff. Modulnivå snarare än closure så
// varje anrop till embedChunk startar med rent state.
let lastRetryAfter: number | null = null

// Retry-After kan vara sekunder eller ett HTTP-datum. Returnerar ms eller
// null om headern saknas/omöjlig att tolka.
function parseRetryAfter(v: string | null): number | null {
  if (!v) return null
  const secs = Number(v)
  if (Number.isFinite(secs) && secs >= 0) return secs * 1000
  const d = new Date(v).getTime()
  if (Number.isFinite(d)) return Math.max(0, d - Date.now())
  return null
}

// Exponentiell backoff (1s → 2s → 4s → 8s → 16s) capad på 30s, med jitter
// (±25%). Om Retry-After anges: använd den i stället (respektera API:et).
async function computeBackoff(attempt: number, _status: number | undefined, retryAfterMs: number | null): Promise<number> {
  if (retryAfterMs !== null) return retryAfterMs + Math.floor(Math.random() * 500)
  const base = Math.min(30_000, 1000 * Math.pow(2, attempt - 1))
  const jitter = base * 0.25 * (Math.random() * 2 - 1)
  return Math.max(500, Math.floor(base + jitter))
}

// ── Steg 4: DB-write per rad, parallellt i chunks ────────────────────────────
async function writeEmbeddings(embeddings: Map<string, number[]>): Promise<{ ok: number, errIds: string[], firstErr: string | null }> {
  const entries = [...embeddings.entries()]
  let ok = 0
  const errIds: string[] = []
  let firstErr: string | null = null
  for (let i = 0; i < entries.length; i += DB_CONCURRENCY) {
    const chunk = entries.slice(i, i + DB_CONCURRENCY)
    const results = await Promise.all(chunk.map(async ([id, embedding]) => {
      const res = await sbFetch(`articles?id=eq.${id}`, {
        method: 'PATCH',
        headers: { 'Prefer': 'return=minimal' },
        body: JSON.stringify({ embedding }),
      })
      return res.ok ? { ok: true, id } : { ok: false, id, error: `${res.status} ${(await res.text()).slice(0, 200)}` }
    }))
    for (const r of results) {
      if (r.ok) ok++
      else { errIds.push(r.id); if (firstErr === null) firstErr = (r as { error: string }).error }
    }
  }
  return { ok, errIds, firstErr }
}

// ── Main ─────────────────────────────────────────────────────────────────────
async function main() {
  const args = parseArgs()
  requireEnv()

  console.log(`Fetching embedding queue (episteme_sensory_pro IS NOT NULL AND embedding IS NULL)...`)
  const queue = await fetchQueue(args.limit)
  console.log(`  ${queue.length} rows in queue`)

  if (!queue.length) {
    console.log('Queue empty. Nothing to do.')
    return
  }

  const est = estimateCost(queue)
  console.log(`  Est. tokens: ${est.tokens.toLocaleString()}`)
  console.log(`  Est. cost: $${est.usd.toFixed(3)} (${MODEL} @ $${PRICE_USD_PER_MTOKEN}/M)`)
  console.log(`  Chunks: ${Math.ceil(queue.length / CHUNK)} × ${CHUNK} rows`)

  if (args.dryRun) {
    console.log('\n--dry-run set. Not calling OpenAI. Exiting.')
    return
  }

  console.log(`\nAbout to embed ${queue.length} rows. Continue? (yes/no)`)
  const buf = new Uint8Array(1024)
  const n = await Deno.stdin.read(buf)
  const answer = new TextDecoder().decode(buf.subarray(0, n || 0)).trim().toLowerCase()
  if (answer !== 'yes') {
    console.log('Aborted.')
    return
  }

  const startedAt = Date.now()
  let totalOk = 0, totalDbErr = 0
  const openaiErrors: Array<{ chunk: number, ids: string[], error: string }> = []
  const dbErrors: string[] = []

  for (let i = 0; i < queue.length; i += CHUNK) {
    const chunkIdx = Math.floor(i / CHUNK)
    const chunk = queue.slice(i, i + CHUNK)
    const now = new Date().toISOString().slice(11, 19)
    await Deno.stdout.write(new TextEncoder().encode(`  ${now}  chunk ${chunkIdx + 1}/${Math.ceil(queue.length / CHUNK)} (${chunk.length} rows) → `))

    const result = await embedChunk(chunk)
    if (!result.ok) {
      console.log(`OpenAI ERR (${result.error.slice(0, 80)})`)
      openaiErrors.push({ chunk: chunkIdx, ids: chunk.map(a => a.id), error: result.error })
      continue
    }
    const w = await writeEmbeddings(result.embeddings)
    totalOk += w.ok
    totalDbErr += w.errIds.length
    if (w.errIds.length) dbErrors.push(...w.errIds)
    console.log(`OK ${w.ok}, DB-err ${w.errIds.length}${w.firstErr ? ` (${w.firstErr.slice(0, 60)})` : ''}`)
  }

  const elapsed = ((Date.now() - startedAt) / 1000).toFixed(1)
  console.log(`\nDone in ${elapsed}s.`)
  console.log(`  ok=${totalOk}`)
  console.log(`  openai_errors=${openaiErrors.length} (${openaiErrors.reduce((s, e) => s + e.ids.length, 0)} rows)`)
  console.log(`  db_errors=${totalDbErr}`)

  if (openaiErrors.length || dbErrors.length) {
    const path = `/tmp/batch-embed-${Date.now()}-errors.jsonl`
    const lines: string[] = []
    for (const e of openaiErrors) for (const id of e.ids) lines.push(JSON.stringify({ id, reason: `openai: ${e.error}` }))
    for (const id of dbErrors) lines.push(JSON.stringify({ id, reason: 'db_error (see logs above)' }))
    await Deno.writeTextFile(path, lines.join('\n'))
    console.log(`\nErrored IDs written to ${path}`)
    console.log('  Re-run without --limit to retry (script only picks up rows where embedding IS NULL).')
  }
}

main().catch(e => { console.error(e); Deno.exit(1) })
