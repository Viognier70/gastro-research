// batch-regen-sci.ts
// ────────────────────────────────────────────────────────────────────────────
// Engångskörning: re-score relevance_sci_educator_researcher över hela
// populationen (~45 085 rader) med SKÄRPT prompt (2026-08-23) via Anthropic
// Batches API. 50 % rabatt mot per-anrop, ≤24 h SLO.
//
// BAKGRUND
// Analys 2026-08-23 (post-ORDER 135) visade att relevance_sci_educator_
// researcher kluster 7.03-8.78 (snitt ~8) över alla 27 topics — jämfört med
// ~5 för övriga fyra roller. Grundorsak: rubriken "8-10: directly addresses
// core tasks" fångar forskare/pedagog trivialt eftersom "read peer-reviewed
// research" ÄR core task för dem. Konsekvens: Feed/newsletter-rangordning
// för den rollen degenererar till fetched_at-drift.
//
// FIX-STRATEGI
// 1. Uppdatera _shared/haiku-sci.ts med skärpt prompt (separat commit —
//    pipeline + backfill + sanity börjar då producera korrekta värden för
//    nya artiklar).
// 2. Denna batch re-scorar de 45 085 befintliga raderna.
//
// KRITISK BEGRÄNSNING — SINGLE-COLUMN UPDATE
// ─────────────────────────────────────────────────────────────────────────
// Haiku returnerar ALLA fem role_scores i JSON-svaret. Detta script skriver
// ENDAST relevance_sci_educator_researcher. De andra fyra kolumnerna rörs
// INTE. Motivering:
//
//   (a) Rubrik-skärpningen är designad för educator_researcher specifikt.
//       De övriga fyra rollernas scoring-semantik är oförändrad — deras
//       befintliga värden kommer från en prompt som var korrekt för dem.
//   (b) Haiku är icke-deterministisk på fri text-input. Om vi skulle skriva
//       tillbaka alla fem fält skulle vi köra 45 085 slumpmässiga små
//       omvärderingar av Sommelier/Chef/Meal-Creator/Hospitality-scores.
//       Det är regression-yta utan värde.
//   (c) Audit-diff blir enkel: en kolumn per rad ändras, syns direkt i
//       rescore-report.md. Regression på annan roll = syns omedelbart.
//   (d) Skriv-transaktioner blir smalare → mindre risk för att träffa
//       processing_queue-triggers eller downstream-invalidering.
//
// Ändra INTE writeEducatorOnly till upsert-full-object. Ändra INTE till
// spread-operator. Kolumnnamnet är hardkodat i UPDATE-satsen — explicit
// och grep-bart.
//
// ── FLÖDE ────────────────────────────────────────────────────────────────
// 1. Fetch population (SELECT id, title, abstract, journal WHERE
//    relevance_sci_educator_researcher IS NOT NULL).
// 2. Bygg batch-requests med LOKALT-FRUSEN skärpt prompt.
// 3. Estimera kostnad. Om --dry-run: stanna här.
// 4. Bekräftelse-prompt (interaktivt yes/no).
// 5. Submit batch → skriv batch-id till statefil.
// 6. Poll status var 60 s tills processing_status='ended'.
// 7. Hämta results (JSONL). Parse per rad, extrahera bara
//    role_scores.educator_researcher.
// 8. Om --apply: UPDATE articles SET relevance_sci_educator_researcher =
//    <new> WHERE id = <id>. Annars: bara dry-run-rapport.
// 9. Skriv rapport till out/rescore-educator.md med före/efter per rad.
//
// ── ANVÄNDNING ───────────────────────────────────────────────────────────
// DRY-RUN (default — SUBMITTAR INGEN BATCH, bara estimering):
//   deno run --allow-net --allow-env --allow-read --allow-write \
//     scripts/batch-regen-sci.ts
//
// SAMPLE (preview N slumpartiklar via LIVE Haiku, ingen batch, inga DB-writes;
// skriver till stdout: per-rad före/efter + top-10 by NEW score med titel):
//   deno run --allow-net --allow-env --allow-read --allow-write \
//     scripts/batch-regen-sci.ts --sample 20
//
// SUBMIT batch, poll, apply UPDATEs skarpt:
//   deno run --allow-net --allow-env --allow-read --allow-write \
//     scripts/batch-regen-sci.ts --apply
//
// RESUME en pågående batch (om script:et avbröts efter submit):
//   deno run --allow-net --allow-env --allow-read --allow-write \
//     scripts/batch-regen-sci.ts --resume <batch-id> --apply
//
// Utan --apply men med --resume: hämta results + skriv rapport, INGEN DB-
// skrivning. Använd för att inspektera vad batchen sa innan du skriver.
//
// ── MILJÖ ────────────────────────────────────────────────────────────────
// ANTHROPIC_API_KEY          — Anthropic-nyckel
// SUPABASE_URL               — https://igmkzhdovyhbfgjomrsc.supabase.co
// SUPABASE_SERVICE_ROLE_KEY  — service_role (bypass RLS för read+write)
// ────────────────────────────────────────────────────────────────────────────

const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY')          || ''
const SB_URL        = Deno.env.get('SUPABASE_URL')               || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_KEY        = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')  || ''

const MODEL            = 'claude-haiku-4-5-20251001'
const MAX_TOKENS       = 500
const POLL_INTERVAL_MS = 60_000
const DB_PAGE          = 1000    // Supabase Range-page för population-fetch
const DB_WRITE_RATE_MS = 25      // ~40 UPDATEs/s → 45k rader = ~19 min

const REPORT_PATH     = 'out/rescore-educator.md'
const STATE_DIR       = '/tmp'

// ── Args ─────────────────────────────────────────────────────────────────────
type Args = { apply: boolean, resume?: string, sample?: number }
function parseArgs(): Args {
  const a: Args = { apply: false }
  const argv = Deno.args
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--apply')       a.apply = true
    else if (argv[i] === '--resume') a.resume = argv[++i]
    else if (argv[i] === '--sample') {
      const n = parseInt(argv[++i] || '', 10)
      if (!Number.isFinite(n) || n < 1) {
        console.error(`--sample requires a positive integer, got: ${argv[i] ?? '(nothing)'}`)
        Deno.exit(2)
      }
      a.sample = n
    }
    else { console.error(`Unknown arg: ${argv[i]}`); Deno.exit(2) }
  }
  // Mutex: --sample konflikterar med både --apply och --resume.
  // --sample är preview-mode (live Haiku, ingen batch, ingen DB-skrivning);
  // --apply är produktion (batch + DB); --resume är fortsätt-en-batch. Att
  // blanda dem skulle vara oklart vad som ska hända.
  if (a.sample !== undefined && a.apply) {
    console.error('--sample and --apply are mutually exclusive. --sample is preview-only (no DB writes).')
    Deno.exit(2)
  }
  if (a.sample !== undefined && a.resume) {
    console.error('--sample and --resume are mutually exclusive. --sample runs fresh live calls, --resume polls an existing batch.')
    Deno.exit(2)
  }
  return a
}

// ── Env / utils ──────────────────────────────────────────────────────────────
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

// ── SKÄRPT PROMPT (matchar _shared/haiku-sci.ts v2026-08-23) ────────────────
// Denna prompt är MEDVETET dubblerad från _shared/haiku-sci.ts. Skäl:
//   (1) Batchen ska vara reproducerbar. Om _shared/haiku-sci.ts senare
//       ändras (t.ex. rubrik-tweaks för Chef) ska en resume-körning av
//       denna batch ändå ge samma resultat — frusen artefakt.
//   (2) Batchen är en engångskörning. Kod-duplicering här är acceptabel
//       eftersom scriptet inte längre kommer utvecklas efter denna körning.
//
// ⚠️  SYNK-ANSVAR
// Om _shared/haiku-sci.ts-prompten uppdateras framåt måste denna kopia
// hållas i synk för samma version — annars kör en resume-batch en annan
// prompt än vad pipeline gör. Uppdatera version-taggen nedan vid ändring.
//
// PROMPT-VERSION: v2026-08-24d (ORDER 149 rev 3). Diff mot v2026-08-23:
//   (a) role_label 'Educator/researcher — method & pedagogy in gastronomy'
//       → 'Academic'.
//   (b) Role-specifik clause omskriven från FILTER-fråga ("does this belong
//       to the role?") till PLACERINGS-fråga ("how high should this rank
//       for this reader?"). Motiv: föregående version över-korrigerade —
//       60/100 sample landade på 2. Rollen är sortnyckel, inte filter;
//       varje artikel ska få en placering, inget exkluderas.
//   (c) 8-band rubrik med SPLITTAT 7-8-band: 9-10 / 8 / 7 / 6 / 5 / 3-4 /
//       1-2 / 0. Motiv: sample v-b visade 54/100 på exakt 7 och 81/100 i
//       7-8-bandet — klumpen flyttades från 8-9 utan att lösas upp. Sci-
//       korpusen är dominerad av substantiell fältforskning (precis vad
//       gamla 7-8 beskrev); ett band räckte inte. Ny distinktion:
//         8 = reach beyond specialization
//         7 = self-contained inom specialisering
//         6 = smal/inkrementell inom specialisering
//   (d) "Relevant background" flyttat från 5-6 till bara 5.
//       "Peripheral but present" ligger kvar på 3-4.
//   (e) CRITICAL DISTINCTION skärpt lexikalt: titlar "X using Y" / "X by
//       means of Y" är studie av X med Y som instrument → poängsätt X.
//       9-10 endast när metoden själv introduceras/valideras/jämförs.
//       Motiv: v-b-sample:s enda 9:a-fel var "extrinsic cues on wine
//       evaluation using projective mapping" — projective mapping är
//       verktyg, extrinsic cues är ämnet.
//   (f) Exemption från BE-STRICT-daily-application-basraden oförändrad
//       (v-b). Base score-scale (0-10) och output-JSON oförändrade.
//
// Revidering v2026-08-24c → v2026-08-24d: mjukat upp CRITICAL DISTINCTION.
//   v-c stängde 9-10-bandet helt (0/100) — pedagogik + metod-som-ämne
//   kunde inte nå toppen. Sista stycket omskrivet med explicit pedagogy/
//   curriculum/skills-transfer på 9-10-sidan + "typically 7-8" på "X using
//   Y"-sidan (istället för hård "only 9-10 when method itself").
// Revidering v2026-08-24b → v2026-08-24c: splittad 7-8 + skärpt CRITICAL
// DISTINCTION.
// Revidering v2026-08-24 → v2026-08-24b: 1-5-skala mappad till 0-10.
//
// SYNK: _shared/haiku-sci.ts synkad till v-d i föregående commit
// (order-149 branch). Iterativ kalibrering v-b → v-c → v-d skedde här
// först; efter godkänt v-d-sample fördes prompten över till shared.
function buildSharpenedPrompt(article: { title: string, abstract: string, journal: string }): string {
  const roleList =
    '"sensory_pro":"Sommelier",' +
    '"culinary_pro":"Chef",' +
    '"gastronomy_culture":"Gastronomy",' +
    '"hospitality_mgmt":"F&B Manager",' +
    '"educator_researcher":"Academic"'

  return `Analyze for Gusto Science (culinary/hospitality platform).
Title: "${(article.title || '').slice(0, 200)}"
Abstract: "${(article.abstract || '').slice(0, 400)}"
Journal: "${article.journal || ''}"
Score relevance 0-10. BE STRICT: only high if professional can directly apply in daily work.
8-10: directly addresses core tasks. 5-7: clear indirect application. 1-4: marginal. 0: irrelevant.

The daily-application test above does not apply to educator_researcher. For this role, relevance is measured by transferability across specializations, per the rubric below.

For educator_researcher (the Academic role):

Academic — researchers and educators in gastronomy. This role is defined by breadth of curiosity, not by subject boundary. Specializations vary widely (fermentation science, food policy, sensory analysis, culinary pedagogy), so the corpus is never filtered — only ordered.

Rank by transferability across specializations, not by topical fit.

9-10 — Portable across the whole role. Articles about how gastronomic knowledge is taught, trained, and transmitted (pedagogy, didactics, curriculum, skills transfer), and articles *about* research methods or data collection — new instruments, protocols, sampling approaches, panel design, measurement validity. Useful to every academic regardless of specialization.

8 — Strong within a specialization, with reach beyond it. Findings, techniques, or framings a researcher in an adjacent gastronomic field could act on.

7 — Solid within a specialization, self-contained. Valuable to those already in that field.

6 — Narrow or incremental within a specialization. Small effect, replication, or a single-context result.

5 — Relevant background. Industry, policy, production, or cultural coverage an academic would read for context.

3-4 — Peripheral but present. Consumer, trade, or lifestyle coverage with thin analytical content.

1-2 — Barely touches gastronomy.

0 — Not gastronomy at all.

CRITICAL DISTINCTION: an article that *uses* a method is not an article *about* a method. Standard research reporting with a methods section belongs at 6-8. Reserve 9-10 for work whose subject is the method itself.

Titles of the form "X using Y" describe a study of X with Y as the instrument — score these on X, typically 7-8. Score 9-10 when the article's own contribution is the method, the instrument, or the teaching of the field: introducing, validating, comparing, or reviewing methods, or any work on pedagogy, curriculum, or skills transfer.

Nothing is excluded. Every article receives a placement. If unsure between two scores, choose the higher — this role reads widely by disposition.

Roles: {${roleList}}
Return ONLY JSON: {"role_scores":{"sensory_pro":0,"culinary_pro":0,"gastronomy_culture":0,"hospitality_mgmt":0,"educator_researcher":0},"keywords":["k1","k2"],"core_claim":"one precise factual finding","headline_en":"max 8 words no punctuation","study_type":"experimental|observational|review|meta-analysis|qualitative"}`
}

// ── Steg 1: hämta population ────────────────────────────────────────────────
type Article = {
  id: string
  title: string
  abstract: string
  journal: string
  educator_before: number   // nuvarande relevance_sci_educator_researcher
}

async function fetchPopulation(): Promise<Article[]> {
  // KEYSET-paginering (fix 2026-08-23). Tidigare OFFSET-baserad Range-header
  // tippade över statement_timeout vid offset ~20 000: Postgres tvingades
  // per request filtrera 466k rader mot IS NOT NULL, sortera hela 45k-
  // resultatet på id, skippa <offset> rader, returnera 1000. Kvadratiskt
  // beteende ju djupare — plus Prefer:count=exact på VARJE request tvingade
  // parallell COUNT(*).
  //
  // Keyset använder PK-indexet på id för att skjuta cursor konstant tid
  // framåt: WHERE id > <lastId>. Ingen sortering-om-hela-populationen per
  // request, ingen OFFSET-hopp. Chunk-tid är O(chunk_size) oavsett djup.
  //
  // count=exact körs BARA på första requesten (behövs en gång för progress-
  // loggen). Efterföljande requests skippar den — sparar 45 × redundant COUNT.
  //
  // Ingen ny index behövs. PK på articles.id räcker; per-chunk-filtret mot
  // IS NOT NULL kostar Postgres att skumma ~10× chunk-size rader (10% match-
  // densitet: 45k av 466k), vilket är billigt inom en enda index-range-scan.
  const out: Article[] = []
  let lastId: string | null = null
  let total: number | null = null

  while (true) {
    const isFirst = total === null
    const keyFilter = lastId ? `&id=gt.${lastId}` : ''
    const url =
      `articles?select=id,title,abstract,journal,relevance_sci_educator_researcher` +
      `&relevance_sci_educator_researcher=not.is.null${keyFilter}` +
      `&order=id.asc&limit=${DB_PAGE}`
    const headers: Record<string, string> = {}
    if (isFirst) headers['Prefer'] = 'count=exact'

    const res = await sbFetch(url, { headers })
    if (!res.ok && res.status !== 206) {
      console.error(`Fetch failed at lastId=${lastId ?? 'start'}: HTTP ${res.status} ${await res.text().catch(() => '')}`)
      Deno.exit(3)
    }
    if (isFirst) {
      const range = res.headers.get('content-range') || ''
      total = parseInt(range.split('/')[1] || '0', 10)
    }
    const rows = await res.json() as Array<{
      id: string
      title: string | null
      abstract: string | null
      journal: string | null
      relevance_sci_educator_researcher: number | null
    }>
    for (const r of rows) {
      out.push({
        id: r.id,
        title: r.title || '',
        abstract: r.abstract || '',
        journal: r.journal || '',
        educator_before: Number(r.relevance_sci_educator_researcher) || 0,
      })
    }
    console.log(`  Fetched ${out.length}/${total ?? '?'}`)
    if (rows.length < DB_PAGE) break
    lastId = rows[rows.length - 1].id
  }
  return out
}

// ── Steg 2: bygg batch-requests + estimering ────────────────────────────────
function buildBatchRequests(articles: Article[]): any[] {
  return articles.map(a => ({
    custom_id: a.id,
    params: {
      model: MODEL,
      max_tokens: MAX_TOKENS,
      messages: [{ role: 'user', content: buildSharpenedPrompt(a) }],
    },
  }))
}

// Grov token-estimering: ~4 chars/token engelska. Haiku 4.5 pris:
// $1/M input, $5/M output. Batches API = 50 % rabatt = $0.50/$2.50/M.
function estimateCost(articles: Article[]): { input_tokens: number, output_tokens: number, usd: number } {
  let inTok = 0, outTok = 0
  for (const a of articles) {
    inTok  += Math.ceil(buildSharpenedPrompt(a).length / 4)
    outTok += 300  // typisk svarslängd — role_scores(5) + keywords + core_claim + headline + study_type ~275 tokens
  }
  const usd = (inTok / 1_000_000) * 0.50 + (outTok / 1_000_000) * 2.50
  return { input_tokens: inTok, output_tokens: outTok, usd }
}

// ── Steg 3-5: submit + poll ──────────────────────────────────────────────────
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
    if (c) console.log(`  ${now}  status=${s.processing_status}  processing=${c.processing}  succeeded=${c.succeeded}  errored=${c.errored}`)
    else   console.log(`  ${now}  status=${s.processing_status}`)
    if (s.processing_status === 'ended') return s
    await new Promise(r => setTimeout(r, POLL_INTERVAL_MS))
  }
}

// ── Steg 6-7: hämta results + parse ─────────────────────────────────────────
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
  return (await res.text()).split('\n').filter(Boolean).map(l => JSON.parse(l) as BatchResult)
}

function parseEducatorScore(txt: string): number | null {
  let t = txt.trim().replace(/^```json\s*/, '').replace(/^```\s*/, '').replace(/```[\s\S]*$/, '').trim()
  try {
    const j = JSON.parse(t)
    const v = j?.role_scores?.educator_researcher
    if (typeof v !== 'number' || !Number.isFinite(v)) return null
    if (v < 0 || v > 10) return null   // defensiv range-check
    return v
  } catch (_) {
    return null
  }
}

// ── Steg 8: EXPLICIT SINGLE-COLUMN UPDATE ───────────────────────────────────
// Ändra INTE denna till upsert-full-object. Se header-kommentaren §KRITISK
// BEGRÄNSNING. Kolumnnamnet är hardkodat och grep-bart.
async function writeEducatorOnly(id: string, newEducatorScore: number): Promise<{ ok: true } | { ok: false, reason: string }> {
  const res = await sbFetch(`articles?id=eq.${id}`, {
    method: 'PATCH',
    headers: { 'Prefer': 'return=minimal' },
    // Enda kolumnen som skrivs. Om nya krav uppstår som skulle vilja skriva
    // en annan kolumn — bygg ett eget separat script. Blanda inte in det här.
    body: JSON.stringify({ relevance_sci_educator_researcher: newEducatorScore }),
  })
  if (!res.ok) {
    return { ok: false, reason: `db ${res.status}: ${(await res.text()).slice(0, 200)}` }
  }
  return { ok: true }
}

// ── Steg 9: rapport ─────────────────────────────────────────────────────────
type RowOutcome = {
  id: string
  title: string
  journal: string
  before: number
  after: number | null
  status: 'changed' | 'unchanged' | 'haiku_error' | 'parse_error' | 'db_error'
  reason?: string
}

function fmtNum(n: number | null | undefined, digits = 2): string {
  if (n === null || n === undefined || !Number.isFinite(n)) return '—'
  return n.toFixed(digits)
}

function esc(s: string): string {
  // Markdown-tabellsäkert: | måste escapas, radbrytningar bort.
  return s.replace(/\|/g, '\\|').replace(/\r?\n/g, ' ').slice(0, 120)
}

async function writeReport(
  outcomes: RowOutcome[],
  meta: { batchId: string, mode: 'dry-run' | 'apply', started: string, completed: string, pop: number },
): Promise<void> {
  // Säkra att out/ finns
  try { await Deno.mkdir('out', { recursive: true }) } catch (_) {}

  const changed   = outcomes.filter(o => o.status === 'changed')
  const unchanged = outcomes.filter(o => o.status === 'unchanged')
  const haikuErr  = outcomes.filter(o => o.status === 'haiku_error')
  const parseErr  = outcomes.filter(o => o.status === 'parse_error')
  const dbErr     = outcomes.filter(o => o.status === 'db_error')

  const withAfter = outcomes.filter(o => o.after !== null)
  const meanBefore = withAfter.length ? withAfter.reduce((s, o) => s + o.before, 0) / withAfter.length : 0
  const meanAfter  = withAfter.length ? withAfter.reduce((s, o) => s + (o.after || 0), 0) / withAfter.length : 0
  const meanDelta  = meanAfter - meanBefore

  // Fördelning per heltalsbucket
  const buckets = (arr: number[]) => {
    const b = new Array(11).fill(0)
    for (const v of arr) b[Math.max(0, Math.min(10, Math.round(v)))]++
    return b
  }
  const distBefore = buckets(withAfter.map(o => o.before))
  const distAfter  = buckets(withAfter.map(o => o.after || 0))

  let md = `# Educator-researcher rescore report — ${meta.completed.slice(0, 10)}

## Meta
| | |
|---|---|
| Batch id | \`${meta.batchId}\` |
| Mode | **${meta.mode}** |
| Prompt | sharpened 2026-08-23 (locally frozen in \`batch-regen-sci.ts\`) |
| Column written | \`relevance_sci_educator_researcher\` (single-column UPDATE) |
| Population | ${meta.pop.toLocaleString()} rows |
| Started | ${meta.started} |
| Completed | ${meta.completed} |

## Summary
| Metric | Count |
|---|---|
| Rows processed | ${outcomes.length.toLocaleString()} |
| Changed (delta ≠ 0) | ${changed.length.toLocaleString()} |
| Unchanged | ${unchanged.length.toLocaleString()} |
| Haiku errored | ${haikuErr.length.toLocaleString()} |
| Parse errored | ${parseErr.length.toLocaleString()} |
| DB errored | ${dbErr.length.toLocaleString()} |

## Distribution (score → row count)
| Bucket | Before | After | Delta |
|---:|---:|---:|---:|
`
  for (let i = 10; i >= 0; i--) {
    md += `| ${i} | ${distBefore[i]} | ${distAfter[i]} | ${distAfter[i] - distBefore[i] >= 0 ? '+' : ''}${distAfter[i] - distBefore[i]} |\n`
  }
  md += `\n| Mean | ${fmtNum(meanBefore)} | ${fmtNum(meanAfter)} | ${meanDelta >= 0 ? '+' : ''}${fmtNum(meanDelta)} |\n`

  if (parseErr.length || haikuErr.length || dbErr.length) {
    md += `\n## Errors (first 50)\n| id | status | reason |\n|---|---|---|\n`
    const errs = [...haikuErr, ...parseErr, ...dbErr].slice(0, 50)
    for (const e of errs) md += `| \`${e.id.slice(0, 8)}\` | ${e.status} | ${esc(e.reason || '')} |\n`
  }

  md += `\n## Per-row diff (all ${outcomes.length.toLocaleString()} rows, sorted by |delta| desc)\n\n`
  md += `| id | title | journal | before | after | delta | status |\n`
  md += `|---|---|---|---:|---:|---:|---|\n`

  const sorted = [...outcomes].sort((a, b) => {
    const da = (a.after !== null) ? Math.abs((a.after || 0) - a.before) : -1
    const db = (b.after !== null) ? Math.abs((b.after || 0) - b.before) : -1
    return db - da
  })
  for (const o of sorted) {
    const delta = (o.after !== null) ? (o.after - o.before) : null
    md += `| \`${o.id.slice(0, 8)}\` | ${esc(o.title)} | ${esc(o.journal)} | ${fmtNum(o.before)} | ${fmtNum(o.after)} | ${delta === null ? '—' : (delta >= 0 ? '+' : '') + fmtNum(delta)} | ${o.status} |\n`
  }

  await Deno.writeTextFile(REPORT_PATH, md)
  console.log(`\nReport written: ${REPORT_PATH} (${(md.length / 1024).toFixed(1)} KB, ${outcomes.length.toLocaleString()} rows)`)
}

// ── SAMPLE MODE (live Haiku, ingen batch, inga DB-writes) ──────────────────
// Snabbt preview-läge för att verifiera att den skärpta prompten producerar
// vettiga scores INNAN vi commiterar $43 till Batches. Kör N slumpartiklar
// mot live-Haiku sekventiellt med rate-limit, skriver före/efter till stdout
// per rad + top-10 by new score med titel så bias-fixet kan inspekteras.

const SAMPLE_RATE_LIMIT_MS = 200  // 5 rps — väl under Haikus tak

async function liveHaikuCall(art: Article): Promise<number | null> {
  const prompt = buildSharpenedPrompt(art)
  try {
    const res = await anthropicFetch('/v1/messages', {
      method: 'POST',
      body: JSON.stringify({
        model: MODEL,
        max_tokens: MAX_TOKENS,
        messages: [{ role: 'user', content: prompt }],
      }),
    })
    if (!res.ok) {
      console.error(`  [${art.id.slice(0, 8)}] Haiku HTTP ${res.status}: ${(await res.text()).slice(0, 120)}`)
      return null
    }
    const d = await res.json()
    const txt = d?.content?.[0]?.text || ''
    const score = parseEducatorScore(txt)
    if (score === null) {
      console.error(`  [${art.id.slice(0, 8)}] parse-fail: ${txt.slice(0, 120)}`)
    }
    return score
  } catch (e: any) {
    console.error(`  [${art.id.slice(0, 8)}] exception: ${e?.message ?? e}`)
    return null
  }
}

async function sampleFlow(n: number): Promise<void> {
  console.log(`Sample mode: ${n} random articles via live Haiku (no batch, no DB writes)`)
  console.log(`Fetching population...`)
  const pop = await fetchPopulation()
  if (pop.length === 0) {
    console.log('Empty population. Exiting.')
    return
  }
  console.log(`  ${pop.length.toLocaleString()} articles in population`)

  // Fisher-Yates shuffle → första N. Random ger bredare täckning än first-N-
  // by-id (som skulle vara skewat mot en godtycklig UUID-region).
  const shuffled = [...pop]
  for (let i = shuffled.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1))
    ;[shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]]
  }
  const sample = shuffled.slice(0, Math.min(n, shuffled.length))
  console.log(`Sampling ${sample.length} articles.`)
  console.log(`Est. wall-time: ~${Math.ceil(sample.length * 2.5)}s (Haiku ~2s + ${SAMPLE_RATE_LIMIT_MS}ms rate-limit per call)\n`)

  type SampleRow = { art: Article, after: number | null }
  const results: SampleRow[] = []

  // Per-rad-header
  console.log(`  #  BEFORE   AFTER   DELTA  TITLE`)
  console.log(`  ─  ─────  ──────  ──────  ─────`)

  for (let i = 0; i < sample.length; i++) {
    const art = sample[i]
    const after = await liveHaikuCall(art)
    results.push({ art, after })

    const idx    = String(i + 1).padStart(3)
    const before = art.educator_before.toFixed(2).padStart(5)
    const afterS = after === null ? '   —  ' : after.toFixed(2).padStart(6)
    const delta  = after === null ? '   —  ' : (
      ((after - art.educator_before) >= 0 ? '+' : '') + (after - art.educator_before).toFixed(2)
    ).padStart(6)
    const title  = (art.title || '(no title)').slice(0, 90)
    console.log(`  ${idx}  ${before}  ${afterS}  ${delta}  ${title}`)

    if (i < sample.length - 1) await new Promise(r => setTimeout(r, SAMPLE_RATE_LIMIT_MS))
  }

  // Summary
  const withAfter = results.filter(r => r.after !== null)
  const err       = results.length - withAfter.length
  const meanBefore = withAfter.length ? withAfter.reduce((s, r) => s + r.art.educator_before, 0) / withAfter.length : 0
  const meanAfter  = withAfter.length ? withAfter.reduce((s, r) => s + (r.after || 0), 0)     / withAfter.length : 0

  console.log(`\n─── SUMMARY ───`)
  console.log(`  Sampled:     ${sample.length}`)
  console.log(`  Haiku ok:    ${withAfter.length}`)
  console.log(`  Haiku err:   ${err}`)
  console.log(`  Mean before: ${meanBefore.toFixed(2)}`)
  console.log(`  Mean after:  ${meanAfter.toFixed(2)}`)
  console.log(`  Mean delta:  ${(meanAfter - meanBefore >= 0 ? '+' : '') + (meanAfter - meanBefore).toFixed(2)}`)

  // Top-10 by NEW score — svarar på "handlar de faktiskt om pedagogik/metod?"
  const top10 = [...withAfter].sort((a, b) => (b.after || 0) - (a.after || 0)).slice(0, 10)
  console.log(`\n─── TOP-10 BY NEW SCORE (verifiering: är dessa faktiskt pedagogik/metod?) ───`)
  console.log(`  NEW  BEFORE  DELTA  TITLE / JOURNAL`)
  console.log(`  ───  ──────  ─────  ───────────────`)
  for (const r of top10) {
    const newS   = (r.after || 0).toFixed(2)
    const beforeS = r.art.educator_before.toFixed(2)
    const deltaN = (r.after || 0) - r.art.educator_before
    const deltaS = (deltaN >= 0 ? '+' : '') + deltaN.toFixed(2)
    console.log(`  ${newS}   ${beforeS}   ${deltaS}  ${(r.art.title || '(no title)').slice(0, 110)}`)
    if (r.art.journal) console.log(`                       · ${r.art.journal.slice(0, 100)}`)
  }
  console.log(`\nDone. No DB writes were made. Re-run with --apply to submit batch for full 45k re-score.`)
}

// ── Main-flow för submit-vägen ──────────────────────────────────────────────
async function processResults(
  results: BatchResult[],
  articleMap: Map<string, Article>,
  apply: boolean,
): Promise<RowOutcome[]> {
  const outcomes: RowOutcome[] = []
  let written = 0

  for (const r of results) {
    const id = r.custom_id
    const art = articleMap.get(id)
    const before = art?.educator_before ?? 0
    const meta = { id, title: art?.title || '', journal: art?.journal || '', before }

    if (r.result.type !== 'succeeded' || !r.result.message) {
      outcomes.push({ ...meta, after: null, status: 'haiku_error', reason: `${r.result.type}: ${r.result.error?.message || 'unknown'}` })
      continue
    }
    const txt = r.result.message.content?.[0]?.text || ''
    const newScore = parseEducatorScore(txt)
    if (newScore === null) {
      outcomes.push({ ...meta, after: null, status: 'parse_error', reason: `parse: ${txt.slice(0, 120)}` })
      continue
    }

    // Ingen ändring → skriv inte, spara som unchanged.
    if (Math.abs(newScore - before) < 0.0001) {
      outcomes.push({ ...meta, after: newScore, status: 'unchanged' })
      continue
    }

    if (apply) {
      const w = await writeEducatorOnly(id, newScore)
      if (!w.ok) {
        outcomes.push({ ...meta, after: newScore, status: 'db_error', reason: w.reason })
        continue
      }
      written++
      if (written % 500 === 0) console.log(`  Wrote ${written}`)
      await new Promise(res => setTimeout(res, DB_WRITE_RATE_MS))
    }
    outcomes.push({ ...meta, after: newScore, status: 'changed' })
  }
  if (apply) console.log(`  Wrote ${written} total`)
  return outcomes
}

async function main() {
  const args = parseArgs()
  requireEnv()

  const startedAt = new Date().toISOString()

  // Sample-läge: live Haiku på N slumpartiklar, stdout-preview, inga writes.
  // Kort-vägen — INTE via batch, INGEN state-fil, INGET rapport-.md.
  if (args.sample !== undefined) {
    await sampleFlow(args.sample)
    return
  }

  // Resume-läge: hoppa direkt till poll+process med känd batch-id.
  // Vi behöver dock ändå population-fetch (för before-värden i rapporten).
  if (args.resume) {
    console.log(`Resuming batch ${args.resume}`)
    console.log(`Fetching population for before-values...`)
    const articles = await fetchPopulation()
    const articleMap = new Map(articles.map(a => [a.id, a]))
    console.log(`  ${articles.length} articles in population`)

    const status = await pollUntilDone(args.resume)
    if (!status.results_url) {
      console.error('Batch ended but no results_url — likely canceled or expired')
      Deno.exit(7)
    }
    console.log('Fetching results...')
    const results = await fetchResults(status.results_url)
    console.log(`Processing ${results.length} results${args.apply ? ' + writing to DB' : ' (NO DB writes — omit --apply for dry-run report only)'}...`)
    const outcomes = await processResults(results, articleMap, args.apply)
    await writeReport(outcomes, {
      batchId: args.resume,
      mode: args.apply ? 'apply' : 'dry-run',
      started: startedAt,
      completed: new Date().toISOString(),
      pop: articles.length,
    })
    return
  }

  // Ny körning — inte resume
  console.log(`Fetching population (relevance_sci_educator_researcher IS NOT NULL)...`)
  const articles = await fetchPopulation()
  console.log(`  ${articles.length.toLocaleString()} articles`)

  if (articles.length === 0) {
    console.log('Nothing to do. Exiting.')
    return
  }

  const requests = buildBatchRequests(articles)
  const est = estimateCost(articles)
  console.log(`\nEstimate:`)
  console.log(`  Requests:       ${requests.length.toLocaleString()}`)
  console.log(`  Input tokens:   ${est.input_tokens.toLocaleString()}`)
  console.log(`  Output tokens:  ${est.output_tokens.toLocaleString()}`)
  console.log(`  Cost (Batches, 50% off): $${est.usd.toFixed(2)}`)

  if (!args.apply) {
    console.log(`\nDRY-RUN default — no batch submitted, no DB writes.`)
    console.log(`To submit + apply: re-run with --apply.`)
    console.log(`To test-parse an already-submitted batch without writes: --resume <id>.`)
    return
  }

  // Bekräftelse innan submit — även med --apply. Undviker oavsiktlig $50-submit.
  console.log(`\nAbout to submit ${requests.length} Haiku batch requests and UPDATE`)
  console.log(`relevance_sci_educator_researcher on up to ${requests.length.toLocaleString()} rows.`)
  console.log(`Other four role columns will NOT be touched. Continue? (yes/no)`)
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

  // Statefil så script kan resumas om det avbryts.
  const statePath = `${STATE_DIR}/batch-sci-${batchId}.state.json`
  await Deno.writeTextFile(statePath, JSON.stringify({
    batchId, submittedAt: startedAt, articles: articles.length,
  }, null, 2))
  console.log(`  State written to ${statePath} (for --resume ${batchId} --apply)`)

  const status = await pollUntilDone(batchId)
  if (!status.results_url) {
    console.error('Batch ended but no results_url — likely canceled or expired')
    Deno.exit(7)
  }

  console.log('Fetching results...')
  const results = await fetchResults(status.results_url)
  const articleMap = new Map(articles.map(a => [a.id, a]))
  console.log(`Processing ${results.length} results + writing to DB...`)
  const outcomes = await processResults(results, articleMap, true)
  await writeReport(outcomes, {
    batchId,
    mode: 'apply',
    started: startedAt,
    completed: new Date().toISOString(),
    pop: articles.length,
  })
}

if (import.meta.main) {
  await main()
}
