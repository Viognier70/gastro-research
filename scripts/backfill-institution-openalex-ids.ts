// scripts/backfill-institution-openalex-ids.ts
// ────────────────────────────────────────────────────────────────────────────
// Fas 1 av 3 — geokodnings-backfill 2026-08-03.
//
// KONTEXT:
//   OpenAlex /works/-endpointen returnerar NÄSTAN geo på nested institutions
//   — bara id/display_name/country_code, INTE lat/lng. Geo måste hämtas via
//   /institutions/{id}-endpointen separat. För det behöver vi id:et.
//
//   articles.institution_openalex_ids[] parallell-array till institutions[]
//   finns sedan 2026-07-08, skrivs av backfill-affiliations (och nu daily-
//   fetch OpenAlex-vägen per commit a39f9cb 2026-08-02). Men artiklar som
//   inserterades av daily-fetch mellan 2026-07-08 och 2026-08-02 fick bara
//   institutions[] — inga ids. Populationsräkning 2026-08-02:
//     18 346 har ids · 1 421 saknar (93 % täckning).
//
//   Detta script fyller de 1 421 så vi kan köra fas 2/3.
//
// FLÖDE PER RAD:
//   1. GET /works/doi:{doi}?select=authorships
//   2. Extrahera authorships[].institutions[].id, dedupe på display_name
//      i ordning (samma logik som daily-fetch/backfill-affiliations bygger
//      arrays på — så samma index i institutions[] och institution_openalex_
//      ids[] refererar till samma institution)
//   3. Skydd: räkna extraherade namn mot lagrade institutions[] — om
//      längderna INTE matchar, skip (dataintegritet — vi kan inte skriva en
//      id-array som inte parallelliseras med existing names)
//   4. PATCH articles.institution_openalex_ids
//
// DEPS: migrationen 20260803120000_openalex_institutions_lookup.sql
//       (RPC:n institution_openalex_ids_backfill_candidates).
//
// SÄKERHETSGARANTIER:
//   - --dry-run default. Kräver --live för DB-skrivning.
//   - /tmp-JSONL med gammal/ny data för ångring.
//   - Sanity-cap 3 000 (population 1 421 + overhead).
//   - PATCH bara om vi hittade ≥1 id OCH längdmatchning stämmer.
//
// USAGE:
//   export SERVICE_ROLE_KEY=<key>
//   deno run --allow-net --allow-env --allow-write \
//     scripts/backfill-institution-openalex-ids.ts             # dry-run 100
//   deno run --allow-net --allow-env --allow-write \
//     scripts/backfill-institution-openalex-ids.ts --live       # full skarpt
//
// RATE LIMIT: OpenAlex polite pool 10 req/s. RATE_MS=150 → ~7 req/s.
// 1 421 rader ≈ 4 min wall-clock.
// ────────────────────────────────────────────────────────────────────────────

const SB_URL   = Deno.env.get('SUPABASE_URL') || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_KEY   = Deno.env.get('SERVICE_ROLE_KEY') || ''
const MAILTO   = 'anders@crichton-fock.com'
const RATE_MS  = 150
const MAX_RETRIES = 5
const PROGRESS_EVERY = 100

const argsSet = new Set(Deno.args)
const LIVE = argsSet.has('--live')
const LIMIT_ARG = Deno.args.find(a => a.startsWith('--limit='))
const LIMIT: number | null = LIMIT_ARG
  ? Math.max(1, parseInt(LIMIT_ARG.split('=')[1] || '0', 10))
  : (LIVE ? null : 100)

if (!SB_KEY) { console.error('SERVICE_ROLE_KEY env-var saknas'); Deno.exit(2) }

type Row = { id: string; url: string; institutions: string[] }

function normalizeDoi(raw: string): string {
  let s = (raw || '').trim()
  if (!/^https?:\/\/(?:dx\.)?doi\.org\//i.test(s)) return ''
  while (/^https?:\/\/(?:dx\.)?doi\.org\//i.test(s)) {
    s = s.replace(/^https?:\/\/(?:dx\.)?doi\.org\//i, '')
  }
  return s
}

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms))

function parseRetryAfter(v: string | null): number | null {
  if (!v) return null
  const secs = Number(v)
  if (Number.isFinite(secs) && secs >= 0) return secs * 1000
  const d = new Date(v).getTime()
  if (Number.isFinite(d)) return Math.max(0, d - Date.now())
  return null
}

const BATCH_SIZE = 1000
const POPULATION_SANITY_CAP = 3_000

async function fetchPopulationBatch(pLimit: number): Promise<Row[]> {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/institution_openalex_ids_backfill_candidates`, {
    method: 'POST',
    headers: {
      apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, 'Content-Type': 'application/json'
    },
    body: JSON.stringify({ p_limit: pLimit })
  })
  if (!r.ok) {
    console.error(`RPC institution_openalex_ids_backfill_candidates HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`)
    console.error('Är migrationen 20260803120000_openalex_institutions_lookup.sql applicerad?')
    Deno.exit(3)
  }
  return await r.json() as Row[]
}

type OaResult =
  | { ok: true; names: string[]; ids: string[] }
  | { ok: false; reason: string; status: number }

async function fetchWorkIds(doi: string): Promise<OaResult> {
  const url = `https://api.openalex.org/works/doi:${encodeURIComponent(doi)}?select=authorships&mailto=${MAILTO}`
  let lastStatus = 0
  let lastRetryAfter: number | null = null
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    if (attempt > 0) {
      const base = lastRetryAfter ?? Math.min(30_000, 1000 * Math.pow(2, attempt - 1))
      await sleep(base + Math.floor(Math.random() * 500))
    }
    try {
      const r = await fetch(url, { headers: { 'User-Agent': 'GustoScience-inst-id-backfill/1.0' } })
      lastStatus = r.status
      if (r.status === 404) return { ok: false, reason: 'not in OpenAlex', status: 404 }
      if (r.status === 429 || r.status >= 500) {
        lastRetryAfter = parseRetryAfter(r.headers.get('retry-after'))
        continue
      }
      if (!r.ok) {
        return { ok: false, reason: `HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`, status: r.status }
      }
      const d = await r.json()
      // Samma dedup-logik som daily-fetch (a39f9cb) och backfill-affiliations —
      // parallell-arrays deduped på display_name i samma pass, samma index.
      const authorships = d.authorships || []
      const flatInsts = authorships.flatMap((a: any) => a.institutions || [])
      const seen = new Set<string>()
      const names: string[] = []
      const ids: string[] = []
      for (const inst of flatInsts) {
        const name = inst?.display_name
        if (!name || seen.has(name)) continue
        seen.add(name)
        names.push(name)
        const rawId = (inst?.id || '') as string
        ids.push(rawId.replace(/^https?:\/\/openalex\.org\//, ''))
      }
      return { ok: true, names, ids }
    } catch (e) {
      lastRetryAfter = null
      if (attempt === MAX_RETRIES) {
        return { ok: false, reason: `network: ${(e as Error).message}`, status: -1 }
      }
    }
  }
  return { ok: false, reason: `${MAX_RETRIES} retries på ${lastStatus || 'nätfel'}`, status: lastStatus }
}

async function patchIds(id: string, ids: string[]): Promise<{ ok: true } | { ok: false; error: string }> {
  const r = await fetch(`${SB_URL}/rest/v1/articles?id=eq.${encodeURIComponent(id)}`, {
    method: 'PATCH',
    headers: {
      apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`,
      'Content-Type': 'application/json', Prefer: 'return=minimal'
    },
    body: JSON.stringify({ institution_openalex_ids: ids })
  })
  if (r.ok) return { ok: true }
  return { ok: false, error: `HTTP ${r.status}: ${(await r.text()).slice(0, 200)}` }
}

async function main() {
  console.log(`Läge: ${LIVE ? 'LIVE (skriver till DB)' : 'DRY-RUN (ingen DB-skrivning)'}`)
  if (LIMIT !== null) console.log(`Populationstak: ${LIMIT} rader`)
  console.log(`Rate-limit: ${RATE_MS} ms/anrop → ~${(1000 / RATE_MS).toFixed(1)} req/s\n`)

  const ts = Date.now()
  const logPath = `/tmp/backfill-inst-ids-${LIVE ? 'live' : 'dry'}-${ts}.jsonl`
  const logLines: string[] = []

  let updated = 0, mismatch = 0, empty = 0, notFound = 0, errored = 0, skipped = 0
  let totalProcessed = 0
  let batchNum = 0
  const startedAt = Date.now()
  const seenIds = new Set<string>()

  while (true) {
    batchNum++
    const remaining = LIMIT !== null ? Math.max(0, LIMIT - totalProcessed) : BATCH_SIZE
    if (LIMIT !== null && remaining === 0) break
    const pLimit = LIMIT !== null ? Math.min(BATCH_SIZE, remaining + seenIds.size) : BATCH_SIZE

    const batch = await fetchPopulationBatch(pLimit)
    if (!batch.length) { console.log(`\nBatch ${batchNum}: RPC 0 rader → populationen slut.`); break }
    const newRows = batch.filter(r => !seenIds.has(r.id))
    console.log(`\nBatch ${batchNum}: RPC ${batch.length}, ${newRows.length} nya`)
    if (newRows.length === 0) { console.log('  populationen består av redan-bearbetade rader — klart.'); break }

    for (const row of newRows) {
      seenIds.add(row.id)
      totalProcessed++
      if (totalProcessed > POPULATION_SANITY_CAP) {
        console.error(`\nABORT: bearbetat ${totalProcessed} > sanity-cap ${POPULATION_SANITY_CAP}. Population borde vara ~1 421.`)
        await Deno.writeTextFile(logPath, logLines.join('\n') + '\n')
        Deno.exit(4)
      }

      const doi = normalizeDoi(row.url)
      if (!doi) {
        skipped++
        logLines.push(JSON.stringify({ id: row.id, action: 'skip', reason: 'no doi in url', url: row.url }))
        continue
      }

      const oa = await fetchWorkIds(doi)
      if (!oa.ok) {
        if (oa.status === 404) notFound++; else errored++
        logLines.push(JSON.stringify({ id: row.id, action: 'skip', reason: oa.reason, status: oa.status, doi }))
        await sleep(RATE_MS); continue
      }

      if (oa.ids.length === 0) {
        empty++
        logLines.push(JSON.stringify({ id: row.id, action: 'skip', reason: 'oa returnerade 0 institutions', doi }))
        await sleep(RATE_MS); continue
      }

      // DATAINTEGRITET: parallell-arrays MÅSTE ha samma längd. Om OA nu ger
      // annat antal än det som lagrats (redigerat OA-metadata, dedupe-drift,
      // etc), skriv INTE — vi kan inte matcha id:t till rätt name-slot.
      // Loggas för manuell inspektion.
      if (oa.ids.length !== row.institutions.length) {
        mismatch++
        logLines.push(JSON.stringify({
          id: row.id, action: 'skip', reason: 'array-length mismatch',
          stored_n: row.institutions.length, oa_n: oa.ids.length,
          stored: row.institutions, oa: oa.names
        }))
        await sleep(RATE_MS); continue
      }

      if (!LIVE) {
        updated++
        logLines.push(JSON.stringify({
          id: row.id, action: 'would-update', n_ids: oa.ids.length,
          ids_sample: oa.ids.slice(0, 3)
        }))
      } else {
        const p = await patchIds(row.id, oa.ids)
        if (p.ok) {
          updated++
          logLines.push(JSON.stringify({ id: row.id, action: 'update', n_ids: oa.ids.length, ids: oa.ids }))
        } else {
          errored++
          logLines.push(JSON.stringify({ id: row.id, action: 'error', attempted_ids: oa.ids, error: p.error }))
        }
      }

      await sleep(RATE_MS)
      if (totalProcessed % PROGRESS_EVERY === 0) {
        const secs = ((Date.now() - startedAt) / 1000).toFixed(0)
        console.log(`  ${totalProcessed}  ${LIVE ? 'updated' : 'would'}=${updated}  mismatch=${mismatch}  empty=${empty}  notFound=${notFound}  err=${errored}  (${secs}s)`)
      }
    }
  }

  const elapsed = ((Date.now() - startedAt) / 1000).toFixed(1)
  console.log(`\nKlart på ${elapsed}s. Totalt bearbetat: ${totalProcessed} (${batchNum} batchar)`)
  console.log(`  ${LIVE ? 'uppdaterade' : 'skulle uppdatera'}: ${updated}`)
  console.log(`  längdmismatch (skippat): ${mismatch}`)
  console.log(`  OA returnerade 0 institutions: ${empty}`)
  console.log(`  ej hittade i OpenAlex (404): ${notFound}`)
  console.log(`  fel: ${errored}`)
  if (skipped) console.log(`  hoppade över (no doi extracted): ${skipped}`)

  await Deno.writeTextFile(logPath, logLines.join('\n') + '\n')
  console.log(`\nLog: ${logPath}`)
  if (LIVE) console.log('  Ångring per rad: filtrera loggen på action=update och kör UPDATE articles SET institution_openalex_ids=NULL WHERE id=<id>.')
  else console.log('  (dry-run — ingen DB-skrivning. Granska loggen och kör med --live.)')
}

main().catch(e => { console.error(e); Deno.exit(1) })
