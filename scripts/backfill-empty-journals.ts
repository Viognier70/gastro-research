// scripts/backfill-empty-journals.ts
//
// ORDER 161 (2026-08-25) — backfill av tomt journal-fält via Crossref-först.
//
// KONTEXT
// -------
// Full-DB-räkning 2026-08-25 gav 356/35 107 rader med journal NULL eller tom
// sträng (irrelevant IS NOT TRUE). Fördelning per source:
//   openalex          333
//   endnote            12
//   semantic_scholar   11
//   scopus              0
//   pubmed              0
//
// STRATEGI-BYTE (dry-run 2026-08-25: OpenAlex-only-varianten resolvade 6/20
// och 2/6 var skräp — "DOAJ", "QUT ePrints" — register + arkiv, inte
// publikationer. De 14 misslyckade hade DOI-prefix 10.1145 (ACM), 10.1109
// (IEEE), 10.2991 (Atlantis Press) — konf-utgivare. OpenAlex saknar dem):
//
//   1. **Crossref först.** Prio: message.container-title[0] (tidskrifter OCH
//      proceedings-titel — kanonisk venue-etikett) → message.event.name (det
//      bakomliggande eventet när container saknas — sällsynt) → message.
//      institution.name (avhandlingar). Fångar ACM/IEEE/Atlantis-DOI:erna
//      som OpenAlex saknar.
//   2. **OpenAlex som fallback** när Crossref inte svarar eller saknar venue.
//      Samma fallback-kedja som daily-fetch:626 (primary_location.source →
//      locations[].source) så backfillade rader förblir identiska med vad
//      pipelinen skulle skriva idag för OpenAlex-nåbara Work-records.
//   3. **Svartlista uppenbara icke-publikationer** innan skrivning. DOAJ,
//      ePrints (institutionella repos), Zenodo, arXiv, SSRN etc. Bättre lämna
//      journal tomt än att skriva ett register- eller repository-namn.
//
// endnote/semantic_scholar-raderna: kolla url-fältet för DOI. Har de en DOI
// kan Crossref (och OpenAlex som fallback) slå upp dem. Har de ingen DOI
// (arxiv-preprints, thesis-repos, direktimporterade EndNote-XML) — lämna dem.
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

// ── JUNK-FILTER (ORDER 161-v2) ─────────────────────────────────────────────
// Kalibrerad mot dry-run 2026-08-25 där OpenAlex returnerade "DOAJ (Directory
// of Open Access Journals)" och "QUT ePrints" som venue-namn — register + inst-
// itutionella repos, inte publikationer. Bättre lämna journal tomt än att
// skriva ett registernamn som senare läses som om det vore en tidskrift.
//
// KONSERVATIV: matchar bara namn som OTVETYDIGT är register/arkiv. "Archives
// of X" (t.ex. "Archives of Applied Mechanics") är riktiga tidskrifter och
// filtreras inte bort — endast namn som antingen ÄR ett känt repo eller
// innehåller "repository"/"ePrints" som substring.
const KNOWN_REPO_NAMES = new Set([
  'arxiv', 'biorxiv', 'chemrxiv', 'medrxiv', 'techrxiv', 'engrxiv',
  'ssrn', 'zenodo', 'figshare', 'osf', 'socarxiv', 'psyarxiv',
  'authorea', 'preprints.org', 'hal', 'dspace', 'proquest',
])
function isJunkVenue(name: string): boolean {
  if (!name || !name.trim()) return true
  const s = name.trim().toLowerCase()

  // DOAJ som prefix eller innehåll ("DOAJ (Directory of Open Access Journals)")
  if (s.startsWith('doaj') || s.includes('directory of open access journals')) return true

  // ePrints-baserade institutionella repos ("QUT ePrints", "Uni-of-X ePrints")
  if (/\beprints?\b/.test(s)) return true

  // Genuina "repository"-suffix ("X University Institutional Repository")
  if (/\brepositor(y|io|ium|ie)\b/.test(s)) return true

  // Thesis-registries
  if (s.includes('dissertations and theses')) return true

  // Kända preprint-/data-repositories (exakt match, eller som prefix med paren-
  // tesförklaring). Exempel: "arXiv", "arXiv (Cornell University)", "arXiv.org".
  for (const r of KNOWN_REPO_NAMES) {
    if (s === r) return true
    if (s.startsWith(r + ' (')) return true
    if (s.startsWith(r + ':')) return true
    if (s.startsWith(r + '.')) return true
  }

  return false
}

// ── CROSSREF-LOOKUP (ORDER 161-v2) ─────────────────────────────────────────
// Prio-fält (i ordning, per direktiv):
//   1. message.container-title[0] — tidskriftsnamn för journal-artiklar OCH
//                                    proceedings-titeln för konf-papers
//                                    ("Proceedings of the 2022 CHI Conference…").
//                                    Kanonisk venue-etikett i Crossref.
//   2. message.event.name         — det bakomliggande event-namnet ("CHI 2022").
//                                    Används bara när container-title saknas
//                                    (sällsynt men förekommer för vissa Atlantis-
//                                    och egenpublicerade proceedings).
//   3. message.institution.name   — avhandlingar (institution[0] eller inst.name)
async function crossrefLookup(row: Row): Promise<
  | { ok: true, journal: string, via: 'crossref_container' | 'crossref_event' | 'crossref_institution' }
  | { ok: false, reason: 'no_doi' | 'not_found' | 'no_venue_in_response' | 'http_error' | 'parse_error' }
> {
  const doi = extractDoi(row.url)
  if (!doi) return { ok: false, reason: 'no_doi' }

  const url = `https://api.crossref.org/works/${encodeURIComponent(doi)}?mailto=${encodeURIComponent(OPENALEX_MAILTO)}`
  let res: Response
  try {
    res = await fetch(url, { headers: { 'User-Agent': `GustoScience/1.0 (mailto:${OPENALEX_MAILTO})` } })
  } catch (_e) {
    return { ok: false, reason: 'http_error' }
  }
  if (res.status === 404) return { ok: false, reason: 'not_found' }
  if (!res.ok) return { ok: false, reason: 'http_error' }

  let data: any
  try { data = await res.json() } catch (_e) { return { ok: false, reason: 'parse_error' } }
  const msg = data?.message
  if (!msg || typeof msg !== 'object') return { ok: false, reason: 'parse_error' }

  const container = Array.isArray(msg['container-title']) ? msg['container-title'][0] : msg['container-title']
  if (typeof container === 'string' && container.trim().length > 0) {
    return { ok: true, journal: container.trim(), via: 'crossref_container' }
  }
  const eventName = msg.event?.name
  if (typeof eventName === 'string' && eventName.trim().length > 0) {
    return { ok: true, journal: eventName.trim(), via: 'crossref_event' }
  }
  const inst = Array.isArray(msg.institution) ? msg.institution[0]?.name : msg.institution?.name
  if (typeof inst === 'string' && inst.trim().length > 0) {
    return { ok: true, journal: inst.trim(), via: 'crossref_institution' }
  }
  return { ok: false, reason: 'no_venue_in_response' }
}

// ── ORKESTRATOR ────────────────────────────────────────────────────────────
// Crossref först (Crossref indexerar via DOI så DOI-krav gäller). Om Crossref
// inte har raden (not_found), inte svarar (http_error), eller returnerar ett
// svar utan venue — fall tillbaka på OpenAlex. En del DOI:er finns bara i den
// ena källan.
type LookupOk = { ok: true, journal: string, via: string }
type LookupFail = { ok: false, reason: 'no_lookup_key' | 'no_venue' | 'error' }

async function lookupJournal(row: Row): Promise<LookupOk | LookupFail> {
  const doi = extractDoi(row.url)
  const oaId = extractOpenAlexId(row.url)
  if (!doi && !oaId) return { ok: false, reason: 'no_lookup_key' }

  if (doi) {
    const cr = await crossrefLookup(row)
    if (cr.ok) return { ok: true, journal: cr.journal, via: cr.via }
    // Fall igenom vid not_found / no_venue / http-fel — OpenAlex kan ha rec:et
    await new Promise(r => setTimeout(r, REQ_DELAY_MS))
  }

  const oa = await openalexLookup(row)
  if (oa.ok) return { ok: true, journal: oa.journal, via: `openalex_${oa.via}` }

  if (oa.reason === 'no_journal_in_response') return { ok: false, reason: 'no_venue' }
  return { ok: false, reason: 'error' }
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

  console.log(`\n${apply ? 'APPLY' : 'DRY-RUN'} — startar lookups (Crossref först, OpenAlex fallback; ${REQ_DELAY_MS} ms delay per request)...`)
  const startedAt = Date.now()

  const results = {
    total: population.length,
    resolved: 0,            // journal hittad + passerar junk-filter → skulle skrivas
    junk_filtered: 0,       // hittat venue-namn men det matchar svartlistan (DOAJ, ePrints, repo…)
    no_lookup_key: 0,       // varken openalex-id eller DOI i url
    no_venue: 0,            // hittade DOI/OA-id men båda API:er saknar venue-namn
    error: 0,               // HTTP-/parse-fel
    written: 0,
    write_failed: 0,
  }
  const perSource = new Map<string, { resolved: number, junk: number, no_key: number, no_venue: number, error: number }>()
  type PerSourceKey = 'resolved' | 'junk' | 'no_key' | 'no_venue' | 'error'
  const bump = (s: string, k: PerSourceKey) => {
    const cur = perSource.get(s) ?? { resolved: 0, junk: 0, no_key: 0, no_venue: 0, error: 0 }
    cur[k] += 1
    perSource.set(s, cur)
  }
  // Via-fördelning bland resolved: hur många kom via Crossref vs OpenAlex,
  // och vilket fält (event/container/institution) — visar värdet av strategi-bytet.
  const viaCount = new Map<string, number>()

  // Loggar första 20 OK + första 10 JUNK + första 10 FAIL för stickprov.
  const samples: string[] = []

  for (let i = 0; i < population.length; i++) {
    const row = population[i]
    const src = row.source || '(null)'
    if (i > 0) await new Promise(r => setTimeout(r, REQ_DELAY_MS))

    const r = await lookupJournal(row)
    if (!r.ok) {
      results[r.reason] += 1
      bump(src, r.reason === 'no_lookup_key' ? 'no_key' : r.reason === 'no_venue' ? 'no_venue' : 'error')
      if (samples.filter(s => s.startsWith('FAIL')).length < 10) {
        samples.push(`FAIL [${row.id.slice(0, 8)}] ${src} ${r.reason} url=${(row.url || '').slice(0, 60)}`)
      }
      continue
    }

    // Junk-filter: skriv inte över tomt med ett registernamn
    if (isJunkVenue(r.journal)) {
      results.junk_filtered += 1
      bump(src, 'junk')
      if (samples.filter(s => s.startsWith('JUNK')).length < 10) {
        samples.push(`JUNK [${row.id.slice(0, 8)}] ${src} via=${r.via.padEnd(20)} filtered="${r.journal.slice(0, 60)}"`)
      }
      continue
    }

    results.resolved += 1
    bump(src, 'resolved')
    viaCount.set(r.via, (viaCount.get(r.via) ?? 0) + 1)
    if (samples.filter(s => s.startsWith('OK')).length < 20) {
      samples.push(`OK   [${row.id.slice(0, 8)}] ${src} via=${r.via.padEnd(20)} journal="${r.journal.slice(0, 60)}"`)
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
  console.log(`  → journal resolved (write)   : ${results.resolved}`)
  console.log(`  → junk-filtered (skip write) : ${results.junk_filtered}`)
  console.log(`  → no lookup key              : ${results.no_lookup_key}`)
  console.log(`  → no venue i någon källa     : ${results.no_venue}`)
  console.log(`  → HTTP/parse-fel             : ${results.error}`)
  if (apply) {
    console.log(`  → written to DB              : ${results.written}`)
    console.log(`  → write failed               : ${results.write_failed}`)
  }

  console.log(`\nVia (bland resolved):`)
  for (const [v, n] of [...viaCount.entries()].sort((a, b) => b[1] - a[1])) {
    console.log(`  ${v.padEnd(24)} ${n}`)
  }

  console.log(`\nPer source:`)
  for (const [s, c] of [...perSource.entries()].sort((a, b) => (b[1].resolved + b[1].junk + b[1].no_key + b[1].no_venue + b[1].error) - (a[1].resolved + a[1].junk + a[1].no_key + a[1].no_venue + a[1].error))) {
    console.log(`  ${s.padEnd(20)} resolved=${c.resolved} junk=${c.junk} no_key=${c.no_key} no_venue=${c.no_venue} error=${c.error}`)
  }

  console.log(`\nSamples (första 20 OK + 10 JUNK + 10 FAIL):`)
  for (const s of samples) console.log(`  ${s}`)

  if (!apply) {
    console.log(`\n[dry-run] Inga DB-skrivningar. Kör om med --apply för att skriva.`)
    console.log(`  Kräver att migration 20260825150000_journal_backup_pre_order_161.sql är applicerad först.`)
  }
}

if (import.meta.main) await main()
