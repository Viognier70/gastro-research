// batch-regen-triad.ts
// ────────────────────────────────────────────────────────────────────────────
// Regenererar TRIAD för en lista artikel-IDs via Anthropic Batches API.
// ~50% kostnadsrabatt mot per-anrop, klar inom 24h. Använd när kostnad
// eller volym gör edge-fn-vägen (triad-on-demand/background) opraktisk.
//
// Delar EXAKT samma prompt/parser/validator som edge-fn:erna genom att
// importera _shared/labeled-triad.ts direkt — ingen duplicering, den nya
// prompten (v4, 2026-07-23) används automatiskt.
//
// ── FLÖDE ────────────────────────────────────────────────────────────────
// 1. Läs artikel-IDs (fil eller stdin).
// 2. Hämta title + abstract + insight från Supabase (service_role).
// 3. Bygg Anthropic-batch-requests via buildTriadPrompt.
// 4. Skicka batch. Skriv batch-id till statefil (för resume).
// 5. Poll status var 60:e sek tills processing_status='ended'.
// 6. Hämta results (JSONL). Parse + validate + skriv till DB per artikel.
// 7. Rapportera: successes, validation-fail, DB-fel.
//
// ── ANVÄNDNING ────────────────────────────────────────────────────────────
// Estimera kostnad utan att skicka:
//   deno run --allow-net --allow-env --allow-read \
//     scripts/batch-regen-triad.ts --ids <file> --dry-run
//
// Skicka batch:
//   deno run --allow-net --allow-env --allow-read --allow-write \
//     scripts/batch-regen-triad.ts --ids <file>
//
// Fortsätt en pågående batch (om script:et avbröts):
//   deno run --allow-net --allow-env --allow-read --allow-write \
//     scripts/batch-regen-triad.ts --resume <batch-id>
//
// ── MILJÖ ─────────────────────────────────────────────────────────────────
// ANTHROPIC_API_KEY   — Anthropic-nyckel
// SUPABASE_URL        — https://igmkzhdovyhbfgjomrsc.supabase.co
// SUPABASE_SERVICE_ROLE_KEY — service_role för RLS-bypass (läs+skriv articles)
// ────────────────────────────────────────────────────────────────────────────

import { buildTriadPrompt, parseLabeledProse, validateTriad, fieldsToDbUpdate } from '../supabase/functions/_shared/labeled-triad.ts'

// ── Konfiguration ────────────────────────────────────────────────────────────
const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') || ''
const SB_URL        = Deno.env.get('SUPABASE_URL')      || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_KEY        = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''

const MODEL           = 'claude-sonnet-4-6'
const MAX_TOKENS      = 4000
const POLL_INTERVAL_MS = 60_000  // 60s mellan status-polls (Batches tar timmar)
const DB_CHUNK        = 100      // hur många artiklar per Supabase-request

// ── Args ─────────────────────────────────────────────────────────────────────
type Args = { ids?: string, resume?: string, dryRun: boolean }
function parseArgs(): Args {
  const a: Args = { dryRun: false }
  const argv = Deno.args
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--ids')      a.ids = argv[++i]
    else if (argv[i] === '--resume')  a.resume = argv[++i]
    else if (argv[i] === '--dry-run') a.dryRun = true
    else { console.error(`Unknown arg: ${argv[i]}`); Deno.exit(2) }
  }
  return a
}

// ── Utils ────────────────────────────────────────────────────────────────────
function requireEnv() {
  const missing: string[] = []
  if (!ANTHROPIC_KEY) missing.push('ANTHROPIC_API_KEY')
  if (!SB_KEY)        missing.push('SUPABASE_SERVICE_ROLE_KEY')
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

async function anthropicFetch(path: string, init: RequestInit = {}): Promise<Response> {
  const headers = {
    'x-api-key': ANTHROPIC_KEY,
    'anthropic-version': '2023-06-01',
    'Content-Type': 'application/json',
    ...(init.headers as Record<string, string> || {}),
  }
  return await fetch(`https://api.anthropic.com${path}`, { ...init, headers })
}

// ── Steg 1: läs IDs ──────────────────────────────────────────────────────────
async function readIds(file: string): Promise<string[]> {
  const raw = await Deno.readTextFile(file)
  const ids = raw.split('\n').map(s => s.trim()).filter(Boolean)
  const set = new Set(ids)
  if (set.size < ids.length) {
    console.warn(`Deduped ${ids.length - set.size} repeats in ${file}`)
  }
  const uuidRe = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  const bad = [...set].filter(id => !uuidRe.test(id))
  if (bad.length) {
    console.error(`Invalid UUIDs in ${file}: ${bad.slice(0, 5).join(', ')}${bad.length > 5 ? '...' : ''}`)
    Deno.exit(2)
  }
  return [...set]
}

// ── Steg 2: hämta artikel-data ───────────────────────────────────────────────
type Article = { id: string, title: string, abstract: string, insight: string }

async function fetchArticles(ids: string[]): Promise<Article[]> {
  const out: Article[] = []
  for (let i = 0; i < ids.length; i += DB_CHUNK) {
    const chunk = ids.slice(i, i + DB_CHUNK)
    const inList = chunk.map(id => `"${id}"`).join(',')
    const res = await sbFetch(`articles?select=id,title,abstract,insight&id=in.(${inList})`)
    if (!res.ok) {
      console.error(`Fetch failed at chunk ${i}: HTTP ${res.status} ${await res.text().catch(() => '')}`)
      Deno.exit(3)
    }
    const data = await res.json() as Article[]
    out.push(...data.map(a => ({ id: a.id, title: a.title || '', abstract: a.abstract || '', insight: a.insight || '' })))
    console.log(`  Fetched ${out.length}/${ids.length}`)
  }
  const foundIds = new Set(out.map(a => a.id))
  const missing = ids.filter(id => !foundIds.has(id))
  if (missing.length) {
    console.warn(`WARNING: ${missing.length} article-IDs not found in DB:`)
    missing.slice(0, 5).forEach(id => console.warn(`  ${id}`))
    if (missing.length > 5) console.warn(`  ... ${missing.length - 5} more`)
  }
  return out
}

// ── Steg 3: bygg batch-requests + estimering ─────────────────────────────────
function buildBatchRequests(articles: Article[]): any[] {
  return articles.map(a => ({
    custom_id: a.id,
    params: {
      model: MODEL,
      max_tokens: MAX_TOKENS,
      messages: [{ role: 'user', content: buildTriadPrompt(a) }],
    },
  }))
}

// Grov token-estimering: 1 token ≈ 4 chars för engelska. Sonnet 4.6 pris:
// $3/M input, $15/M output. Batches API = 50% rabatt = $1.50/$7.50/M.
function estimateCost(articles: Article[]): { input_tokens: number, output_tokens: number, usd: number } {
  let inTok = 0, outTok = 0
  for (const a of articles) {
    const prompt = buildTriadPrompt(a)
    inTok += Math.ceil(prompt.length / 4)
    // Output: ~15 fält × 60 ord × 1.3 tokens/ord ≈ 1170 tokens, avrunda uppåt.
    outTok += 1400
  }
  const usd = (inTok / 1_000_000) * 1.50 + (outTok / 1_000_000) * 7.50
  return { input_tokens: inTok, output_tokens: outTok, usd }
}

// ── Steg 4: skicka batch ─────────────────────────────────────────────────────
async function submitBatch(requests: any[]): Promise<string> {
  const res = await anthropicFetch('/v1/messages/batches', {
    method: 'POST',
    body: JSON.stringify({ requests }),
  })
  if (!res.ok) {
    console.error(`Batch submit failed: HTTP ${res.status} ${await res.text()}`)
    Deno.exit(4)
  }
  const data = await res.json()
  return data.id as string
}

// ── Steg 5: poll status ──────────────────────────────────────────────────────
type BatchStatus = {
  id: string
  processing_status: 'in_progress' | 'canceling' | 'ended'
  request_counts?: { processing: number, succeeded: number, errored: number, canceled: number, expired: number }
  results_url?: string | null
  ended_at?: string | null
}

async function getBatchStatus(id: string): Promise<BatchStatus> {
  const res = await anthropicFetch(`/v1/messages/batches/${id}`)
  if (!res.ok) {
    console.error(`Status check failed: HTTP ${res.status} ${await res.text()}`)
    Deno.exit(5)
  }
  return await res.json() as BatchStatus
}

async function pollUntilDone(id: string): Promise<BatchStatus> {
  console.log(`Polling ${id} every ${POLL_INTERVAL_MS / 1000}s (batch may take up to 24h)...`)
  while (true) {
    const s = await getBatchStatus(id)
    const c = s.request_counts
    const now = new Date().toISOString().slice(11, 19)
    if (c) {
      console.log(`  ${now}  status=${s.processing_status}  processing=${c.processing}  succeeded=${c.succeeded}  errored=${c.errored}`)
    } else {
      console.log(`  ${now}  status=${s.processing_status}`)
    }
    if (s.processing_status === 'ended') return s
    await new Promise(r => setTimeout(r, POLL_INTERVAL_MS))
  }
}

// ── Steg 6: hämta results (JSONL) + parse + skriv ────────────────────────────
type BatchResult = {
  custom_id: string
  result: {
    type: 'succeeded' | 'errored' | 'canceled' | 'expired'
    message?: { content: Array<{ text: string }> }
    error?: { type: string, message: string }
  }
}

async function fetchResults(url: string): Promise<BatchResult[]> {
  const res = await fetch(url, {
    headers: { 'x-api-key': ANTHROPIC_KEY, 'anthropic-version': '2023-06-01' },
  })
  if (!res.ok) {
    console.error(`Results fetch failed: HTTP ${res.status} ${await res.text()}`)
    Deno.exit(6)
  }
  const text = await res.text()
  return text.split('\n').filter(Boolean).map(line => JSON.parse(line) as BatchResult)
}

type WriteReport = {
  ok: number
  sonnet_error: number
  parse_error: number
  db_error: number
  errored_ids: Array<{ id: string, reason: string }>
}

async function processResults(results: BatchResult[]): Promise<WriteReport> {
  const rep: WriteReport = { ok: 0, sonnet_error: 0, parse_error: 0, db_error: 0, errored_ids: [] }
  for (const r of results) {
    const id = r.custom_id
    if (r.result.type !== 'succeeded' || !r.result.message) {
      rep.sonnet_error++
      rep.errored_ids.push({ id, reason: `sonnet ${r.result.type}: ${r.result.error?.message || 'unknown'}` })
      continue
    }
    const txt = r.result.message.content?.[0]?.text || ''
    const parsed = parseLabeledProse(txt.trim())
    const parseErr = validateTriad(parsed)
    if (parseErr) {
      rep.parse_error++
      rep.errored_ids.push({ id, reason: `parse: ${parseErr}` })
      continue
    }
    const update = { triad_pending: false, triad_pending_at: null, ...fieldsToDbUpdate(parsed.fields) }
    const res = await sbFetch(`articles?id=eq.${id}`, {
      method: 'PATCH',
      headers: { 'Prefer': 'return=minimal' },
      body: JSON.stringify(update),
    })
    if (!res.ok) {
      rep.db_error++
      rep.errored_ids.push({ id, reason: `db ${res.status}: ${(await res.text()).slice(0, 200)}` })
      continue
    }
    rep.ok++
    if (rep.ok % 100 === 0) console.log(`  Wrote ${rep.ok}/${results.length}`)
  }
  return rep
}

// ── Main ─────────────────────────────────────────────────────────────────────
async function main() {
  const args = parseArgs()
  requireEnv()

  // Resume-läge: hoppa direkt till poll+process med känd batch-id.
  if (args.resume) {
    console.log(`Resuming batch ${args.resume}`)
    const status = await pollUntilDone(args.resume)
    if (!status.results_url) {
      console.error('Batch ended but no results_url — likely canceled or expired')
      Deno.exit(7)
    }
    console.log('Fetching results...')
    const results = await fetchResults(status.results_url)
    console.log(`Processing ${results.length} results...`)
    const rep = await processResults(results)
    console.log(`\nDone. ok=${rep.ok} sonnet_error=${rep.sonnet_error} parse_error=${rep.parse_error} db_error=${rep.db_error}`)
    if (rep.errored_ids.length) {
      const path = `/tmp/batch-triad-${args.resume}-errors.jsonl`
      await Deno.writeTextFile(path, rep.errored_ids.map(e => JSON.stringify(e)).join('\n'))
      console.log(`Errored IDs written to ${path}`)
    }
    return
  }

  if (!args.ids) {
    console.error('Missing --ids <file> (or --resume <batch-id>)')
    Deno.exit(2)
  }

  console.log(`Reading IDs from ${args.ids}...`)
  const ids = await readIds(args.ids)
  console.log(`  ${ids.length} unique IDs`)

  console.log(`Fetching article data from Supabase...`)
  const articles = await fetchArticles(ids)
  console.log(`  ${articles.length} articles loaded`)

  console.log(`Building batch requests...`)
  const requests = buildBatchRequests(articles)
  const est = estimateCost(articles)
  console.log(`  ${requests.length} requests`)
  console.log(`  Est. input tokens:  ${est.input_tokens.toLocaleString()}`)
  console.log(`  Est. output tokens: ${est.output_tokens.toLocaleString()}`)
  console.log(`  Est. cost (Batches, 50% off): $${est.usd.toFixed(2)}`)

  if (args.dryRun) {
    console.log('\n--dry-run set. Not submitting. Exiting.')
    return
  }

  // Bekräftelse-prompt (interaktiv) — undvik oavsiktlig $500-submit.
  console.log(`\nAbout to submit ${requests.length} requests. Continue? (yes/no)`)
  const buf = new Uint8Array(1024)
  const n = await Deno.stdin.read(buf)
  const answer = new TextDecoder().decode(buf.subarray(0, n || 0)).trim().toLowerCase()
  if (answer !== 'yes') {
    console.log('Aborted.')
    return
  }

  console.log('Submitting batch...')
  const batchId = await submitBatch(requests)
  console.log(`  Batch submitted: ${batchId}`)

  // Skriv statefil så script kan resumas om det avbryts.
  const statePath = `/tmp/batch-triad-${batchId}.state.json`
  await Deno.writeTextFile(statePath, JSON.stringify({ batchId, ids, submittedAt: new Date().toISOString() }, null, 2))
  console.log(`  State written to ${statePath} (for --resume)`)

  const status = await pollUntilDone(batchId)
  if (!status.results_url) {
    console.error('Batch ended but no results_url — likely canceled or expired')
    Deno.exit(7)
  }

  console.log('Fetching results...')
  const results = await fetchResults(status.results_url)
  console.log(`Processing ${results.length} results...`)
  const rep = await processResults(results)

  console.log(`\nDone.`)
  console.log(`  ok=${rep.ok}`)
  console.log(`  sonnet_error=${rep.sonnet_error}`)
  console.log(`  parse_error=${rep.parse_error}`)
  console.log(`  db_error=${rep.db_error}`)
  if (rep.errored_ids.length) {
    const errPath = `/tmp/batch-triad-${batchId}-errors.jsonl`
    await Deno.writeTextFile(errPath, rep.errored_ids.map(e => JSON.stringify(e)).join('\n'))
    console.log(`\nErrored IDs written to ${errPath}`)
    console.log('  Retry: re-run this script with --ids <fil-med-dessa-IDs> efter du utrett orsakerna.')
  }
}

main().catch(e => { console.error(e); Deno.exit(1) })
