// scripts/backfill-authors-openalex.ts
// ────────────────────────────────────────────────────────────────────────────
// Backfill av truncerade Scopus-författare via OpenAlex.
//
// KONTEXT:
//   Scopus-parsern (fixad i commit ffa7ab7) sparade 100 % singelnamn för
//   13 540 rader eftersom Scopus STANDARD-view saknar authors-arrayen.
//   Stickprov 2026-08-01 (n=20, scripts/stickprov-author-parity.ts):
//   90 % (18/20) räddningsbara via OpenAlex DOI-lookup, 0 % url utan
//   doi.org. Extrapolerat ~12 186 lagbara av 13 540.
//
// MÅLPOPULATION (via RPC authors_backfill_candidates — filtret ligger i SQL,
// inte i PostgREST-query; kommat i `not ilike '%,%'` släpps tyst av
// PostgREST och pullade en gång 236 174 rader i stället för 13 540):
//   source='scopus'
//   AND authors NOT LIKE '%,%'                (singelnamn = trunkerat)
//   AND url LIKE '%doi.org/%'                 (uppslagningsbart)
//   AND episteme_sensory_pro IS NOT NULL      (passerat TRIAD → citerbar)
//
// Utan TRIAD-villkoret: 304 623 rader (rå Scopus utan analys — ingen
// användare ser dem, ingen citation blir fel om vi hoppar över dem).
//
// DEPS: migrationen 20260801120000_authors_backfill_candidates_rpc.sql
//       måste vara applicerad (manuellt via SQL-editorn).
//
// PER RAD:
//   1. Extrahera raw DOI ur url (strip https://doi.org/-prefix)
//   2. GET api.openalex.org/works/doi:<doi>?mailto=…
//   3. authorships[].author.display_name → filter(Boolean) → join(', ')
//   4. PATCH BARA om OpenAlex returnerar >1 namn. ≤1 = ingen förbättring,
//      skriv inte över. Populationsfiltret garanterar att stored value är
//      1 namn.
//   5. Logga varje operation som JSONL för ångrings-möjlighet.
//
// SÄKERHETSGARANTIER:
//   - --dry-run är DEFAULT. Kräver explicit --live för DB-skrivning.
//   - Ångrings-logg: /tmp/backfill-authors-<ts>.jsonl med
//     {id, action, old, new, ...}. Rows där action='update' kan
//     rulls tillbaka via UPDATE articles SET authors=<old> WHERE id=<id>.
//   - Populationsfiltret hoppar över redan uppdaterade rader vid
//     återupptagning (efter en lyckad PATCH innehåller authors komma).
//
// USAGE:
//   Dry-run (default, 100 rader — visar vad som SKULLE skrivas):
//     export SERVICE_ROLE_KEY=<key>
//     deno run --allow-net --allow-env --allow-write \
//       scripts/backfill-authors-openalex.ts
//
//   Skarp körning (efter accepterad dry-run):
//     export SERVICE_ROLE_KEY=<key>
//     deno run --allow-net --allow-env --allow-write \
//       scripts/backfill-authors-openalex.ts --live
//
//   Begränsa (fungerar i båda lägen):
//     deno run --allow-net --allow-env --allow-write \
//       scripts/backfill-authors-openalex.ts --live --limit=500
//
// RATE LIMIT: OpenAlex polite pool 10 req/s. RATE_MS=150 → ~7 req/s.
// 13 540 rader ≈ 35 min wall-clock.
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

type Row = { id: string; url: string; authors: string }

// Speglar production-helpern i daily-fetch. While-loopen tål även flerfaldig
// prefix (redan korrupta rader). Returnerar '' om url inte har doi.org.
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

// SANITY: målpopulationen är ~13 540 (stickprov 2026-08-01). Ett tidigare
// försök filtrera direkt via PostgREST släppte `authors=not.ilike.*,*` tyst
// (kommat i mönstret tolkas som arg-sep) och pullade 236 174 rader. Filter-
// logiken ligger nu i SQL via RPC authors_backfill_candidates.
//
// PostgREST db-max-rows cappar RPC-svaret till 1000 → main() looper.
const BATCH_SIZE = 1000
const POPULATION_SANITY_CAP = 20_000  // totalt bearbetade rader per körning

async function fetchPopulationBatch(pLimit: number): Promise<Row[]> {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/authors_backfill_candidates`, {
    method: 'POST',
    headers: {
      apikey: SB_KEY,
      Authorization: `Bearer ${SB_KEY}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ p_limit: pLimit })
  })
  if (!r.ok) {
    console.error(`RPC authors_backfill_candidates HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`)
    console.error('Är migrationen 20260801120000_authors_backfill_candidates_rpc.sql applicerad?')
    Deno.exit(3)
  }
  const rows = await r.json() as Row[]
  return rows.filter(x => x.authors && x.authors.trim())
}

type OaResult =
  | { ok: true; authors: string; n: number }
  | { ok: false; reason: string; status: number }

async function openAlexAuthors(doi: string): Promise<OaResult> {
  const url = `https://api.openalex.org/works/doi:${encodeURIComponent(doi)}?mailto=${MAILTO}`
  let lastStatus = 0
  let lastRetryAfter: number | null = null
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    if (attempt > 0) {
      const base = lastRetryAfter ?? Math.min(30_000, 1000 * Math.pow(2, attempt - 1))
      await sleep(base + Math.floor(Math.random() * 500))
    }
    try {
      const r = await fetch(url, { headers: { 'User-Agent': 'GustoScience-backfill/1.0' } })
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
      const names = (d.authorships || [])
        .map((a: any) => (a.author?.display_name || '').trim())
        .filter(Boolean)
      if (!names.length) return { ok: false, reason: 'OA authorships tomma', status: 200 }
      return { ok: true, authors: names.join(', '), n: names.length }
    } catch (e) {
      lastRetryAfter = null
      if (attempt === MAX_RETRIES) {
        return { ok: false, reason: `network: ${(e as Error).message}`, status: -1 }
      }
    }
  }
  return { ok: false, reason: `${MAX_RETRIES} retries på ${lastStatus || 'nätfel'}`, status: lastStatus }
}

async function patchAuthors(id: string, authors: string): Promise<{ ok: true } | { ok: false; error: string }> {
  const r = await fetch(`${SB_URL}/rest/v1/articles?id=eq.${encodeURIComponent(id)}`, {
    method: 'PATCH',
    headers: {
      apikey: SB_KEY,
      Authorization: `Bearer ${SB_KEY}`,
      'Content-Type': 'application/json',
      Prefer: 'return=minimal'
    },
    body: JSON.stringify({ authors })
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
  const logPath = `/tmp/backfill-authors-${LIVE ? 'live' : 'dry'}-${ts}.jsonl`
  const logLines: string[] = []

  let updated = 0, unchanged = 0, notFound = 0, errored = 0, skipped = 0
  let totalProcessed = 0
  let batchNum = 0
  const startedAt = Date.now()

  // Dedup över yttre loop. RPC:s population omfattar alla rader vars authors
  // saknar komma — updated → faller ur (får komma), MEN unchanged/errored
  // står kvar för alltid. Utan seenIds skulle nästa fetch returnera samma
  // unchanged-tail i evighet.
  const seenIds = new Set<string>()

  while (true) {
    batchNum++
    // Med --limit: hämta max det som återstår upp till taket. Utan --limit:
    // full batch. Extra pad för att RPC:n även kan returnera redan-sedda
    // rader (unchanged/errored) som filtreras bort på klientsidan.
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
        console.error('Målpopulationen är ~13 540. Kontrollera RPC-definitionen.')
        await Deno.writeTextFile(logPath, logLines.join('\n') + '\n')
        console.error(`Log skriven till ${logPath} innan abort.`)
        Deno.exit(4)
      }

      const doi = normalizeDoi(row.url)
      if (!doi) {
        // Populationsfiltret garanterar url ilike '%doi.org/%', men extractDoi
        // kan ändå strippa till '' om url:en är 'https://doi.org/' utan
        // efterföljande kod. Räkna som skip.
        skipped++
        logLines.push(JSON.stringify({ id: row.id, action: 'skip', reason: 'no doi extracted from url', url: row.url }))
        continue
      }

      const oa = await openAlexAuthors(doi)
      if (!oa.ok) {
        if (oa.status === 404) notFound++
        else errored++
        logLines.push(JSON.stringify({ id: row.id, action: 'skip', reason: oa.reason, status: oa.status, doi }))
        await sleep(RATE_MS)
        continue
      }

      // KRAV: skriv INTE över med färre eller lika många namn. Population-
      // filter garanterar 1 stored → skip om oa.n ≤ 1.
      if (oa.n <= 1) {
        unchanged++
        logLines.push(JSON.stringify({ id: row.id, action: 'skip', reason: 'oa ≤ 1 namn — ingen förbättring', oa_n: oa.n, old: row.authors }))
        await sleep(RATE_MS)
        continue
      }

      if (!LIVE) {
        updated++
        logLines.push(JSON.stringify({ id: row.id, action: 'would-update', old: row.authors, new: oa.authors, oa_n: oa.n }))
      } else {
        const p = await patchAuthors(row.id, oa.authors)
        if (p.ok) {
          updated++
          logLines.push(JSON.stringify({ id: row.id, action: 'update', old: row.authors, new: oa.authors, oa_n: oa.n }))
        } else {
          errored++
          logLines.push(JSON.stringify({ id: row.id, action: 'error', old: row.authors, attempted: oa.authors, error: p.error }))
        }
      }

      await sleep(RATE_MS)
      if (totalProcessed % PROGRESS_EVERY === 0) {
        const secs = ((Date.now() - startedAt) / 1000).toFixed(0)
        console.log(`  ${totalProcessed}  ${LIVE ? 'updated' : 'would-update'}=${updated}  unchanged=${unchanged}  notFound=${notFound}  err=${errored}  (${secs}s)`)
      }
    }
  }

  const elapsed = ((Date.now() - startedAt) / 1000).toFixed(1)
  console.log(`\nKlart på ${elapsed}s. Totalt bearbetat: ${totalProcessed} (${batchNum} batchar)`)
  console.log(`  ${LIVE ? 'uppdaterade' : 'skulle uppdatera'}: ${updated}`)
  console.log(`  oförändrade (OA ≤1 namn): ${unchanged}`)
  console.log(`  ej hittade i OpenAlex (404): ${notFound}`)
  console.log(`  fel: ${errored}`)
  if (skipped) console.log(`  hoppade över (no doi extracted): ${skipped}`)

  await Deno.writeTextFile(logPath, logLines.join('\n') + '\n')
  console.log(`\nLog: ${logPath}`)
  if (LIVE) {
    console.log('  Ångring per rad: filtrera loggen på action=update och kör')
    console.log('  UPDATE articles SET authors=<old> WHERE id=<id> för de raderna.')
  } else {
    console.log('  (dry-run — ingen DB-skrivning. Granska loggen och kör med --live.)')
  }
}

main().catch(e => { console.error(e); Deno.exit(1) })
