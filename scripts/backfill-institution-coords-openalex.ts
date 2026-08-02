// scripts/backfill-institution-coords-openalex.ts
// ────────────────────────────────────────────────────────────────────────────
// Väg A geokodning: institution_coords via OpenAlex DOI-lookup.
//
// KONTEXT:
//   27 407 TRIAD-artiklar har institutions[] populerat men saknar
//   institution_coords → dyker upp i sidebar/flöde-räkningen men får ingen
//   prick på kartan. Coverage-copyn 2026-08-02: 2 389 av 29 166 (8 %) —
//   luckor och samarbetsmönster blir artefakter av vad som råkat berikas.
//
//   university_rankings (Väg B):     453 rader, 5 % coverage
//   unika institutioner i backlog:   9 194 (verifierat 2026-08-02)
//   → Väg B: 9 194 anrop + fuzzy matchning mot institutions[]-strängar
//   → Väg A: 27 407 anrop, ingen matchning, exakt geo per artikel
//   Väg A tar 68 min istället för ~25 vid 7 req/s. Engångskörning →
//   fuzzy matchnings-risken är oacceptabel för besparingen.
//
// MÅLPOPULATION (via RPC institution_coords_backfill_candidates):
//   institutions IS NOT NULL AND array_length > 0
//   AND institution_coords IS NULL
//   AND url LIKE '%doi.org/%'
//   AND episteme_sensory_pro IS NOT NULL   (TRIAD-gate — icke-TRIAD-rader
//                                            är osynliga i produkten)
//
// DEPS: migrationen 20260802130000_institution_coords_backfill_candidates_rpc.sql
//       måste vara applicerad (manuellt via SQL-editorn).
//
// PER RAD:
//   1. Extrahera raw DOI ur url
//   2. GET api.openalex.org/works/doi:<doi>?select=authorships&mailto=…
//   3. authorships[].institutions[].geo → filter(has lat) → dedupe by name
//      → [{name, lat, lng, country}]
//   4. PATCH BARA om OpenAlex returnerar ≥1 coord-entry. 0 = OA saknar geo
//      för institutionen, skriv inte tom array (populationsfiltret skulle
//      hoppa över raden nästa gång annars — men med tom [] skulle
//      partial-indexet uq_articles_url ändå inte träffas, och rader utan
//      geo ligger kvar i backlog för framtida OA-uppdateringar).
//   5. Ångrings-JSONL i /tmp.
//
// SÄKERHETSGARANTIER:
//   - --dry-run är DEFAULT. Kräver explicit --live för DB-skrivning.
//   - Ångrings-logg: /tmp/backfill-coords-<ts>.jsonl.
//     Rader med action='update' kan rullas tillbaka via
//     UPDATE articles SET institution_coords=NULL WHERE id=<id>.
//   - Populationsfiltret hoppar över redan uppdaterade rader vid
//     återupptagning (efter lyckad PATCH är institution_coords non-null).
//   - Sanity-cap 40 000 (populationen är 27 407 idag; overhead för icke-
//     targetbara rader som samlas i seenIds ger lite luft).
//
// USAGE:
//   Dry-run (default, 100 rader):
//     export SERVICE_ROLE_KEY=<key>
//     deno run --allow-net --allow-env --allow-write \
//       scripts/backfill-institution-coords-openalex.ts
//
//   Skarp körning (efter accepterad dry-run):
//     export SERVICE_ROLE_KEY=<key>
//     deno run --allow-net --allow-env --allow-write \
//       scripts/backfill-institution-coords-openalex.ts --live
//
//   Begränsa: --limit=500 (fungerar i båda lägen)
//
// RATE LIMIT: OpenAlex polite pool 10 req/s. RATE_MS=150 → ~7 req/s.
// 27 407 rader ≈ 68 min wall-clock. Ingen SCOPUS-quota berörs.
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

if (!SB_KEY) {
  console.error('SERVICE_ROLE_KEY env-var saknas')
  Deno.exit(2)
}

type Row = { id: string; url: string; institutions: string[] }
type CoordEntry = { name: string; lat: number; lng: number; country: string }

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
const POPULATION_SANITY_CAP = 40_000  // 27 407 target + overhead för seenIds

async function fetchPopulationBatch(pLimit: number): Promise<Row[]> {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/institution_coords_backfill_candidates`, {
    method: 'POST',
    headers: {
      apikey: SB_KEY,
      Authorization: `Bearer ${SB_KEY}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ p_limit: pLimit })
  })
  if (!r.ok) {
    console.error(`RPC institution_coords_backfill_candidates HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`)
    console.error('Är migrationen 20260802130000_institution_coords_backfill_candidates_rpc.sql applicerad?')
    Deno.exit(3)
  }
  const rows = await r.json() as Row[]
  return rows.filter(x => x.institutions && x.institutions.length > 0)
}

type OaResult =
  | { ok: true; coords: CoordEntry[] }
  | { ok: false; reason: string; status: number }

async function openAlexCoords(doi: string): Promise<OaResult> {
  const url = `https://api.openalex.org/works/doi:${encodeURIComponent(doi)}?select=authorships&mailto=${MAILTO}`
  let lastStatus = 0
  let lastRetryAfter: number | null = null
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    if (attempt > 0) {
      const base = lastRetryAfter ?? Math.min(30_000, 1000 * Math.pow(2, attempt - 1))
      await sleep(base + Math.floor(Math.random() * 500))
    }
    try {
      const r = await fetch(url, { headers: { 'User-Agent': 'GustoScience-coord-backfill/1.0' } })
      lastStatus = r.status
      if (r.status === 404) return { ok: false, reason: 'not in OpenAlex', status: 404 }
      if (r.status === 429 || r.status >= 500) {
        lastRetryAfter = parseRetryAfter(r.headers.get('retry-after'))
        continue
      }
      if (!r.ok) {
        const body = (await r.text()).slice(0, 200)
        return { ok: false, reason: `HTTP ${r.status}: ${body}`, status: r.status }
      }
      const d = await r.json()
      // Speglar mapper i daily-fetch.ts (rad 466-471) och backfill-affiliations
      // (rad 97-106): flatMap authorships → institutions, filter geo.latitude,
      // dedupe by name. Country_code som land per coord-entry.
      const authorships = d.authorships || []
      const flatInsts = authorships.flatMap((a: any) => a.institutions || [])
      const coords: CoordEntry[] = flatInsts
        .filter((i: any) => i?.geo?.latitude)
        .map((i: any) => ({
          name: i.display_name,
          lat: i.geo.latitude,
          lng: i.geo.longitude,
          country: i.country_code
        }))
        .filter((v: CoordEntry, i: number, a: CoordEntry[]) =>
          a.findIndex((x) => x.name === v.name) === i)
      return { ok: true, coords }
    } catch (e) {
      lastRetryAfter = null
      if (attempt === MAX_RETRIES) {
        return { ok: false, reason: `network: ${(e as Error).message}`, status: -1 }
      }
    }
  }
  return { ok: false, reason: `${MAX_RETRIES} retries på ${lastStatus || 'nätfel'}`, status: lastStatus }
}

async function patchCoords(id: string, coords: CoordEntry[]): Promise<{ ok: true } | { ok: false; error: string }> {
  const r = await fetch(`${SB_URL}/rest/v1/articles?id=eq.${encodeURIComponent(id)}`, {
    method: 'PATCH',
    headers: {
      apikey: SB_KEY,
      Authorization: `Bearer ${SB_KEY}`,
      'Content-Type': 'application/json',
      Prefer: 'return=minimal'
    },
    body: JSON.stringify({ institution_coords: coords })
  })
  if (r.ok) return { ok: true }
  return { ok: false, error: `HTTP ${r.status}: ${(await r.text()).slice(0, 200)}` }
}

async function main() {
  console.log(`Läge: ${LIVE ? 'LIVE (skriver till DB)' : 'DRY-RUN (ingen DB-skrivning)'}`)
  if (LIMIT !== null) console.log(`Populationstak: ${LIMIT} rader`)
  console.log(`Rate-limit: ${RATE_MS} ms/anrop → ~${(1000 / RATE_MS).toFixed(1)} req/s`)
  console.log(`Batchstorlek: ${BATCH_SIZE} (PostgREST db-max-rows-cap)\n`)

  const ts = Date.now()
  const logPath = `/tmp/backfill-coords-${LIVE ? 'live' : 'dry'}-${ts}.jsonl`
  const logLines: string[] = []

  let updated = 0, noGeo = 0, notFound = 0, errored = 0, skipped = 0
  let totalProcessed = 0
  let batchNum = 0
  const startedAt = Date.now()

  // Dedup över yttre loop. Rader med noGeo/errored ligger kvar i populationen
  // (institution_coords fortsatt null) → nästa RPC-batch returnerar dem igen.
  // seenIds hindrar oändlig re-fetch.
  const seenIds = new Set<string>()

  while (true) {
    batchNum++
    const remaining = LIMIT !== null ? Math.max(0, LIMIT - totalProcessed) : BATCH_SIZE
    if (LIMIT !== null && remaining === 0) break
    const pLimit = LIMIT !== null ? Math.min(BATCH_SIZE, remaining + seenIds.size) : BATCH_SIZE

    const batch = await fetchPopulationBatch(pLimit)
    if (!batch.length) {
      console.log(`\nBatch ${batchNum}: RPC returnerade 0 → populationen slut.`)
      break
    }
    const newRows = batch.filter(r => !seenIds.has(r.id))
    console.log(`\nBatch ${batchNum}: RPC ${batch.length} rader, ${newRows.length} nya (${batch.length - newRows.length} redan bearbetade i denna körning)`)
    if (newRows.length === 0) {
      console.log('  populationen består av rader som redan bearbetats — klart.')
      break
    }

    for (let i = 0; i < newRows.length; i++) {
      const row = newRows[i]
      seenIds.add(row.id)
      totalProcessed++

      if (totalProcessed > POPULATION_SANITY_CAP) {
        console.error(`\nABORT: bearbetat ${totalProcessed} rader > sanity-cap ${POPULATION_SANITY_CAP}.`)
        console.error('Målpopulationen är ~27 407. Kontrollera RPC-definitionen.')
        await Deno.writeTextFile(logPath, logLines.join('\n') + '\n')
        console.error(`Log skriven till ${logPath} innan abort.`)
        Deno.exit(4)
      }

      const doi = normalizeDoi(row.url)
      if (!doi) {
        skipped++
        logLines.push(JSON.stringify({ id: row.id, action: 'skip', reason: 'no doi extracted from url', url: row.url }))
        continue
      }

      const oa = await openAlexCoords(doi)
      if (!oa.ok) {
        if (oa.status === 404) notFound++
        else errored++
        logLines.push(JSON.stringify({ id: row.id, action: 'skip', reason: oa.reason, status: oa.status, doi }))
        await sleep(RATE_MS)
        continue
      }

      // OA hittade artikeln men saknar geo för dess institutioner (t.ex.
      // långsvans-institutioner OA inte hunnit indexera). Skriv INTE tom
      // array — raden ligger kvar i backlog för framtida OA-uppdateringar.
      if (oa.coords.length === 0) {
        noGeo++
        logLines.push(JSON.stringify({ id: row.id, action: 'skip', reason: 'oa har artikel men ingen inst.geo', stored_institutions: row.institutions.length }))
        await sleep(RATE_MS)
        continue
      }

      if (!LIVE) {
        updated++
        logLines.push(JSON.stringify({
          id: row.id, action: 'would-update',
          n_coords: oa.coords.length,
          n_institutions_stored: row.institutions.length,
          coords_sample: oa.coords.slice(0, 3).map(c => ({ name: c.name, country: c.country }))
        }))
      } else {
        const p = await patchCoords(row.id, oa.coords)
        if (p.ok) {
          updated++
          logLines.push(JSON.stringify({
            id: row.id, action: 'update',
            n_coords: oa.coords.length,
            coords: oa.coords
          }))
        } else {
          errored++
          logLines.push(JSON.stringify({
            id: row.id, action: 'error',
            attempted_n_coords: oa.coords.length,
            error: p.error
          }))
        }
      }

      await sleep(RATE_MS)
      if (totalProcessed % PROGRESS_EVERY === 0) {
        const secs = ((Date.now() - startedAt) / 1000).toFixed(0)
        console.log(`  ${totalProcessed}  ${LIVE ? 'updated' : 'would-update'}=${updated}  noGeo=${noGeo}  notFound=${notFound}  err=${errored}  (${secs}s)`)
      }
    }
  }

  const elapsed = ((Date.now() - startedAt) / 1000).toFixed(1)
  console.log(`\nKlart på ${elapsed}s. Totalt bearbetat: ${totalProcessed} (${batchNum} batchar)`)
  console.log(`  ${LIVE ? 'uppdaterade' : 'skulle uppdatera'}: ${updated}`)
  console.log(`  OA har artikel men saknar inst.geo: ${noGeo}`)
  console.log(`  ej hittade i OpenAlex (404): ${notFound}`)
  console.log(`  fel: ${errored}`)
  if (skipped) console.log(`  hoppade över (no doi extracted): ${skipped}`)

  await Deno.writeTextFile(logPath, logLines.join('\n') + '\n')
  console.log(`\nLog: ${logPath}`)
  if (LIVE) {
    console.log('  Ångring per rad: filtrera loggen på action=update och kör')
    console.log('  UPDATE articles SET institution_coords=NULL WHERE id=<id> för de raderna.')
  } else {
    console.log('  (dry-run — ingen DB-skrivning. Granska loggen och kör med --live.)')
  }
}

main().catch(e => { console.error(e); Deno.exit(1) })
