// scripts/backfill-openalex-institutions.ts
// ────────────────────────────────────────────────────────────────────────────
// Fas 2 av 3 — geokodnings-backfill 2026-08-03.
//
// KONTEXT:
//   Fas 1 (backfill-institution-openalex-ids.ts) har fyllt articles.
//   institution_openalex_ids för alla TRIAD-artiklar (uppskattat 19 767
//   efter Fas 1). Detta script tar de UNIKA id:na, slår upp geo per id
//   mot OpenAlex /institutions/{id}-endpointen (som har geo), och skriver
//   till lokal openalex_institutions-tabell.
//
//   Fas 3 (SQL: refresh_institution_coords()) tar sedan bulk-UPDATE
//   articles.institution_coords via JOIN på institution_openalex_ids[]-
//   elementen — sekunder, ingen mer OpenAlex-quota.
//
// UPPSKATTAD POPULATION: 3-5k unika id:n bland 19 767 artiklar (samma
// institutioner publicerar upprepat). Verifiera efter fas 1:
//   select count(*) from public.openalex_institutions_missing(50000);
//
// FLÖDE PER ID:
//   1. GET /institutions/{id}?select=id,display_name,geo,country_code
//   2. Extrahera geo.latitude, geo.longitude, geo.country_code (fallback
//      till top-level country_code om geo saknas)
//   3. UPSERT till openalex_institutions (lat/lng får vara null om OA
//      saknar geo för institutionen — några förekommer)
//   4. Loggning: geo/no-geo/notfound-fördelning
//
// DEPS: migrationen 20260803120000_openalex_institutions_lookup.sql
//       + Fas 1-scriptet körts skarpt.
//
// SÄKERHETSGARANTIER:
//   - --dry-run default. Kräver --live för DB-skrivning.
//   - /tmp-JSONL med hämtad data för granskning.
//   - Sanity-cap 15 000 id (om populationen är större → utred, höj inte blint).
//   - UPSERT (on-conflict id do update) → idempotent, kan köras om.
//
// USAGE:
//   export SERVICE_ROLE_KEY=<key>
//   deno run --allow-net --allow-env --allow-write \
//     scripts/backfill-openalex-institutions.ts            # dry-run 100
//   deno run --allow-net --allow-env --allow-write \
//     scripts/backfill-openalex-institutions.ts --live      # full skarpt
//
// RATE LIMIT: OpenAlex polite pool 10 req/s. RATE_MS=150 → ~7 req/s.
// 3 000-5 000 id ≈ 8-13 min wall-clock.
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

type InstRecord = {
  id: string; display_name: string;
  lat: number | null; lng: number | null; country_code: string | null;
}

function sleep(ms: number) { return new Promise(r => setTimeout(r, ms)) }

function parseRetryAfter(v: string | null): number | null {
  if (!v) return null
  const secs = Number(v)
  if (Number.isFinite(secs) && secs >= 0) return secs * 1000
  const d = new Date(v).getTime()
  if (Number.isFinite(d)) return Math.max(0, d - Date.now())
  return null
}

const BATCH_SIZE = 1000
// Höj inte utan att först verifiera att populationen är legitim (se
// doc-block i migration 20260803120000_openalex_institutions_lookup.sql).
// Faktisk pop 2026-08-03 var 11 177 — förr-uppskattningen 3-5k underskattade
// hur många unika institutioner ~19 767 TRIAD-artiklar täcker.
const POPULATION_SANITY_CAP = 15_000

async function fetchMissingIds(pLimit: number): Promise<string[]> {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/openalex_institutions_missing`, {
    method: 'POST',
    headers: {
      apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, 'Content-Type': 'application/json'
    },
    body: JSON.stringify({ p_limit: pLimit })
  })
  if (!r.ok) {
    console.error(`RPC openalex_institutions_missing HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`)
    console.error('Är migrationen 20260803120000_openalex_institutions_lookup.sql applicerad?')
    Deno.exit(3)
  }
  const rows = await r.json() as Array<{id: string}>
  return rows.map(r => r.id).filter(Boolean)
}

type OaResult =
  | { ok: true; rec: InstRecord }
  | { ok: false; reason: string; status: number }

async function fetchInstitution(id: string): Promise<OaResult> {
  const url = `https://api.openalex.org/institutions/${encodeURIComponent(id)}?select=id,display_name,geo,country_code&mailto=${MAILTO}`
  let lastStatus = 0
  let lastRetryAfter: number | null = null
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    if (attempt > 0) {
      const base = lastRetryAfter ?? Math.min(30_000, 1000 * Math.pow(2, attempt - 1))
      await sleep(base + Math.floor(Math.random() * 500))
    }
    try {
      const r = await fetch(url, { headers: { 'User-Agent': 'GustoScience-inst-lookup/1.0' } })
      lastStatus = r.status
      if (r.status === 404) return { ok: false, reason: 'not in OpenAlex', status: 404 }
      if (r.status === 429 || r.status >= 500) {
        lastRetryAfter = parseRetryAfter(r.headers.get('retry-after'))
        continue
      }
      if (!r.ok) return { ok: false, reason: `HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`, status: r.status }
      const d = await r.json()
      const geo = d.geo || {}
      const lat = typeof geo.latitude  === 'number' ? geo.latitude  : null
      const lng = typeof geo.longitude === 'number' ? geo.longitude : null
      // country_code: prefer geo.country_code (mer specifik), fallback till top-level
      const cc  = geo.country_code || d.country_code || null
      return { ok: true, rec: {
        id, display_name: d.display_name || '', lat, lng, country_code: cc
      }}
    } catch (e) {
      lastRetryAfter = null
      if (attempt === MAX_RETRIES) return { ok: false, reason: `network: ${(e as Error).message}`, status: -1 }
    }
  }
  return { ok: false, reason: `${MAX_RETRIES} retries på ${lastStatus || 'nätfel'}`, status: lastStatus }
}

async function upsertInstitution(rec: InstRecord): Promise<{ ok: true } | { ok: false; error: string }> {
  // PostgREST upsert via Prefer: resolution=merge-duplicates. Primärnyckel
  // id, sätt on-conflict så att uppdaterade fetched_at reflekterar senaste OA-svaret.
  const body = { ...rec, fetched_at: new Date().toISOString() }
  const r = await fetch(`${SB_URL}/rest/v1/openalex_institutions`, {
    method: 'POST',
    headers: {
      apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`,
      'Content-Type': 'application/json',
      Prefer: 'resolution=merge-duplicates,return=minimal'
    },
    body: JSON.stringify(body)
  })
  if (r.ok) return { ok: true }
  return { ok: false, error: `HTTP ${r.status}: ${(await r.text()).slice(0, 200)}` }
}

async function main() {
  console.log(`Läge: ${LIVE ? 'LIVE (skriver till DB)' : 'DRY-RUN (ingen DB-skrivning)'}`)
  if (LIMIT !== null) console.log(`Populationstak: ${LIMIT} rader`)
  console.log(`Rate-limit: ${RATE_MS} ms/anrop → ~${(1000 / RATE_MS).toFixed(1)} req/s\n`)

  const ts = Date.now()
  const logPath = `/tmp/backfill-oa-inst-${LIVE ? 'live' : 'dry'}-${ts}.jsonl`
  const logLines: string[] = []

  let hasGeo = 0, noGeo = 0, notFound = 0, errored = 0
  let totalProcessed = 0
  let batchNum = 0
  const startedAt = Date.now()
  const seenIds = new Set<string>()

  while (true) {
    batchNum++
    const remaining = LIMIT !== null ? Math.max(0, LIMIT - totalProcessed) : BATCH_SIZE
    if (LIMIT !== null && remaining === 0) break
    const pLimit = LIMIT !== null ? Math.min(BATCH_SIZE, remaining + seenIds.size) : BATCH_SIZE

    const ids = await fetchMissingIds(pLimit)
    if (!ids.length) { console.log(`\nBatch ${batchNum}: RPC 0 id → populationen slut.`); break }
    const newIds = ids.filter(id => !seenIds.has(id))
    console.log(`\nBatch ${batchNum}: RPC ${ids.length} id, ${newIds.length} nya`)
    if (newIds.length === 0) { console.log('  populationen består av redan-bearbetade id — klart.'); break }

    for (const id of newIds) {
      seenIds.add(id)
      totalProcessed++
      if (totalProcessed > POPULATION_SANITY_CAP) {
        console.error(`\nABORT: bearbetat ${totalProcessed} > sanity-cap ${POPULATION_SANITY_CAP}.`)
        await Deno.writeTextFile(logPath, logLines.join('\n') + '\n')
        Deno.exit(4)
      }

      const oa = await fetchInstitution(id)
      if (!oa.ok) {
        if (oa.status === 404) notFound++; else errored++
        logLines.push(JSON.stringify({ id, action: 'skip', reason: oa.reason, status: oa.status }))
        await sleep(RATE_MS); continue
      }

      if (oa.rec.lat !== null && oa.rec.lng !== null) hasGeo++
      else noGeo++

      if (!LIVE) {
        logLines.push(JSON.stringify({ id, action: 'would-upsert', rec: oa.rec }))
      } else {
        const p = await upsertInstitution(oa.rec)
        if (p.ok) {
          logLines.push(JSON.stringify({ id, action: 'upsert', rec: oa.rec }))
        } else {
          errored++
          if (oa.rec.lat !== null && oa.rec.lng !== null) hasGeo--
          else noGeo--
          logLines.push(JSON.stringify({ id, action: 'error', rec: oa.rec, error: p.error }))
        }
      }

      await sleep(RATE_MS)
      if (totalProcessed % PROGRESS_EVERY === 0) {
        const secs = ((Date.now() - startedAt) / 1000).toFixed(0)
        console.log(`  ${totalProcessed}  hasGeo=${hasGeo}  noGeo=${noGeo}  notFound=${notFound}  err=${errored}  (${secs}s)`)
      }
    }
  }

  const elapsed = ((Date.now() - startedAt) / 1000).toFixed(1)
  console.log(`\nKlart på ${elapsed}s. Totalt bearbetat: ${totalProcessed} id (${batchNum} batchar)`)
  console.log(`  med geo (upserted lat/lng): ${hasGeo}`)
  console.log(`  utan geo (OA saknar koordinater): ${noGeo}`)
  console.log(`  ej hittade (404): ${notFound}`)
  console.log(`  fel: ${errored}`)

  await Deno.writeTextFile(logPath, logLines.join('\n') + '\n')
  console.log(`\nLog: ${logPath}`)
  if (LIVE) {
    console.log(`\nNästa steg: kör fas 3 i SQL-editorn för att skriva institution_coords:`)
    console.log(`  select public.refresh_institution_coords();`)
    console.log(`Returvärdet = antal artiklar vars institution_coords uppdaterades.`)
  } else {
    console.log('  (dry-run — ingen DB-skrivning. Granska loggen och kör med --live.)')
  }
}

main().catch(e => { console.error(e); Deno.exit(1) })
