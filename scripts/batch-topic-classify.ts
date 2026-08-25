// batch-topic-classify.ts
// ────────────────────────────────────────────────────────────────────────────
// ORDER 153 (2026-08-25) — AI-baserad topic-klassificering av uncategorized-
// residualen som keyword-runderna 4+5 inte kunde nå. ~3,714 artiklar via
// Anthropic Batches API (Haiku 4.5, 50% rabatt, ≤24h SLO).
//
// BAKGRUND
// ORDER 147 (runda 4) flyttade 3,448 av 7,574 uncategorized-rader. ORDER 152
// (runda 5) med OpenAlex-meta-vokabulär tog ytterligare 421. Kvar: ~3,714
// rader vars keywords är för generiska ("computer science", "philosophy",
// "world wide web") eller för specifika för att matcha någon av de 27
// topic-slug-listorna. Manuell inspektion av stickprov visade materialet
// ÄR gastronomiskt, men klassificeringsspåret via keywords är uttömt.
//
// AI-spåret: Haiku 4.5 läser title + abstract + journal + keywords och
// tilldelar en av 27 topic-slugs — eller 'uncategorized' om ingen passar.
// Explicit "får inte gissa"-instruktion i prompten så residualen efter
// AI blir en ren "hör verkligen ingenstans"-hink.
//
// KRITISK BEGRÄNSNING — SINGLE-COLUMN UPDATE
// ────────────────────────────────────────────────────────────────────────
// Scriptet skriver ENDAST articles.topic. Ingen annan kolumn rörs.
// Motivering (samma logik som batch-regen-sci.ts):
//   (a) Prompten är designad specifikt för topic-tilldelning. Att skriva
//       tillbaka annan Haiku-output skulle blanda in slumpmässiga små
//       omvärderingar av data som redan är korrekt scored.
//   (b) Audit-diff blir enkel: topic-kolumnen per rad, syns direkt i
//       topic-classify-report.md.
//   (c) Rollback via topic_backup-tabellen (migration 20260825130000_
//       topic_backup_pre_order_153.sql) täcker bara topic. Skriver vi
//       fler kolumner har vi ingen rollback för dem.
//
// Ändra INTE writeTopicOnly till upsert-full-object.
//
// ── FLÖDE ────────────────────────────────────────────────────────────────
// 1. Fetch population (SELECT id, title, abstract, journal, keywords
//    WHERE topic = 'uncategorized' AND irrelevant IS NOT TRUE).
// 2. Bygg batch-requests med lokalt-frusen classification-prompt.
// 3. Estimera kostnad. Om --dry-run: stanna här.
// 4. Bekräftelse-prompt (interaktivt yes/no).
// 5. Submit batch → skriv batch-id till statefil.
// 6. Poll status var 60s tills processing_status='ended'.
// 7. Hämta results (JSONL). Parse per rad, extrahera topic-slug.
//    Validera mot 27+1-slug-whitelist; ogiltiga → parse_error.
// 8. Om --apply: UPDATE articles SET topic = <new> WHERE id = <id>.
//    Ingen ändring om new === 'uncategorized' (ingen nettoflytt).
// 9. Skriv rapport till out/topic-classify.md med före/efter per rad.
//
// ── ANVÄNDNING ───────────────────────────────────────────────────────────
// DRY-RUN (default — SUBMITTAR INGEN BATCH, bara estimering):
//   deno run --allow-net --allow-env --allow-read --allow-write \
//     scripts/batch-topic-classify.ts
//
// SAMPLE (preview N slumpartiklar via LIVE Haiku, ingen batch, inga writes):
//   deno run --allow-net --allow-env --allow-read --allow-write \
//     scripts/batch-topic-classify.ts --sample 30
//
// SUBMIT + apply skarpt:
//   deno run --allow-net --allow-env --allow-read --allow-write \
//     scripts/batch-topic-classify.ts --apply
//
// RESUME en pågående batch:
//   deno run --allow-net --allow-env --allow-read --allow-write \
//     scripts/batch-topic-classify.ts --resume <batch-id> --apply
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
const MAX_TOKENS       = 200      // topic-slug + short JSON, mycket kompakt
const POLL_INTERVAL_MS = 60_000
const DB_PAGE          = 1000
const DB_WRITE_RATE_MS = 25       // ~40 UPDATEs/s → 3.7k rader = ~2 min

const REPORT_PATH     = 'out/topic-classify.md'
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
  if (a.sample !== undefined && a.apply) {
    console.error('--sample and --apply are mutually exclusive.')
    Deno.exit(2)
  }
  if (a.sample !== undefined && a.resume) {
    console.error('--sample and --resume are mutually exclusive.')
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

// ── 27+1 TOPIC-SLUG WHITELIST ───────────────────────────────────────────────
// De 27 slugs som existerar i knowledge_map_topics + 'uncategorized' som
// fallback när modellen genuint inte kan tilldela. Ordning matchar frekvens
// vid tidpunkten för scriptet (2026-08-25) — större kategorier först
// underlättar modellens intuition men påverkar inte matchning.
//
// Om nya topics adderas i taxonomin: uppdatera denna lista OCH prompten.
const VALID_TOPICS = [
  'food_science', 'fermentation_science', 'sensory_evaluation',
  'flavor_science', 'food_psychology', 'nutritional_science',
  'hospitality', 'food_anthropology', 'gastronomy', 'sommellerie',
  'appetite_research', 'culinary_science', 'multisensory',
  'atmospherics', 'culinary_education', 'novel_foods', 'art_science',
  'experiential_dining', 'food_pairing', 'food_behavior',
  'food_technology', 'servicescape', 'molecular_mixology',
  'crossmodal', 'sensory_training', 'neurogastronomy',
  'uncategorized',    // ⚠ 28:e valida svaret — modellen får välja denna
                      // när materialet genuint inte passar i övriga 27.
] as const
const VALID_TOPIC_SET = new Set(VALID_TOPICS)

// ── CLASSIFICATION PROMPT ──────────────────────────────────────────────────
// PROMPT-VERSION: v2026-08-25 (ORDER 153 v1). Frusen artefakt i denna fil —
// om _shared/ senare får en topic-classify-modul måste den hållas i synk för
// resume-safety. Ingen sync-plikt idag (existerar inte).
//
// LEXIKAL LÄRDOM FRÅN ORDER 149: klassificera på vad artikeln HANDLAR om,
// inte på vilka metoder/material den nämner. En artikel som USES GC-MS på
// vinaromer är om vinaromer (flavor_science), inte om kemi. En artikel som
// STUDERAR konsumentbeteende på hotell är om hospitality, inte om statistik.
//
// UNCATEGORIZED SOM VALID SVAR: materialet är residual efter TVÅ keyword-
// runder. En del hör genuint ingenstans. En modell som tvingas välja
// kommer att gissa (som ORDER 149:s filter-prompt gjorde med role-scores).
// Explicit "får välja uncategorized" ger en ärlig residual istället för
// slumpmässig topic-fördelning i botten.
function buildClassificationPrompt(article: {
  title: string, abstract: string, journal: string, keywords: string[]
}): string {
  const title    = (article.title    || '').slice(0, 200)
  const abstract = (article.abstract || '').slice(0, 600)
  const journal  = (article.journal  || '').slice(0, 100)
  const kwList   = (article.keywords || []).slice(0, 15).join(', ')

  return `Classify this article by its PRIMARY TOPIC — what the article is fundamentally ABOUT, not the methods or materials it happens to use.

CRITICAL RULE: an article that USES a technique on a subject belongs to the subject, not the technique.
  - "Aroma compounds in wine using GC-MS" → about wine flavor, not chromatography
  - "Consumer behavior at hotels using regression" → about hospitality, not statistics
  - "Nutritional intake in adolescents measured by FFQ" → about nutrition, not survey methods
Journal name is a strong prior but not decisive. Keywords are useful hints but often noisy (OpenAlex meta-tags).

Return exactly ONE slug from this list:
- food_science         — chemistry, technology, processing, safety, shelf life
- fermentation_science — fermentation, cheese, yogurt, brewing, koji, lactic acid bacteria
- sensory_evaluation   — panels, descriptive analysis, consumer acceptability, thresholds
- flavor_science       — aroma, taste chemistry, volatiles, flavor release
- food_psychology      — consumer behavior, food choice, eating psychology
- nutritional_science  — nutrition, dietary intake, health outcomes
- hospitality          — restaurants, hotels, service quality, guest experience
- food_anthropology    — cultural food practices, culinary history, food heritage
- gastronomy           — cuisine as art, culinary culture, haute cuisine
- sommellerie          — wine expertise, tasting, oenology, viticulture
- appetite_research    — hunger, satiety, food reward, satiation
- culinary_science     — cooking techniques, kitchen chemistry, ingredient behavior
- multisensory         — multi-sense integration in eating experience
- atmospherics         — restaurant environment, lighting, ambiance
- culinary_education   — chef training, culinary schools, cooking pedagogy
- novel_foods          — alternative proteins, lab-grown meat, insect protein
- art_science          — food art, plating aesthetics, culinary aesthetics
- experiential_dining  — immersive dining, themed restaurants
- food_pairing         — flavor pairing, wine pairing
- food_behavior        — eating habits, dietary behavior, food intake patterns
- food_technology      — food innovation, novel processing
- servicescape         — physical service environment design
- molecular_mixology   — molecular gastronomy, spherification, cocktail science
- crossmodal           — cross-sensory perception in food (sound/color/texture)
- sensory_training     — sensory panel training, taste/olfactory training
- neurogastronomy      — brain science of flavor, taste neuroscience

If the article genuinely does not fit ANY of the 27 topics above, return "uncategorized". Do NOT guess. Choosing "uncategorized" is a valid answer for material that is off-topic or too broad to place — it is better to be honest than to force-fit.

Title:    "${title}"
Journal:  "${journal}"
Keywords: ${kwList || '(none)'}
Abstract: "${abstract}"

Return ONLY JSON: {"topic":"slug"}`
}

// ── Steg 1: hämta population ────────────────────────────────────────────────
type Article = {
  id: string
  title: string
  abstract: string
  journal: string
  keywords: string[]
  topic_before: string   // nuvarande articles.topic (alltid 'uncategorized' vid start)
}

async function fetchPopulation(): Promise<Article[]> {
  // KEYSET-paginering (samma mönster som batch-regen-sci.ts). WHERE-clause
  // ändrad: topic = 'uncategorized' AND irrelevant IS NOT TRUE.
  const out: Article[] = []
  let lastId: string | null = null
  let total: number | null = null

  while (true) {
    const isFirst = total === null
    const keyFilter = lastId ? `&id=gt.${lastId}` : ''
    const url =
      `articles?select=id,title,abstract,journal,keywords,topic` +
      `&topic=eq.uncategorized&irrelevant=not.is.true${keyFilter}` +
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
      keywords: string[] | null
      topic: string | null
    }>
    for (const r of rows) {
      out.push({
        id: r.id,
        title: r.title || '',
        abstract: r.abstract || '',
        journal: r.journal || '',
        keywords: r.keywords || [],
        topic_before: r.topic || 'uncategorized',
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
      messages: [{ role: 'user', content: buildClassificationPrompt(a) }],
    },
  }))
}

// Grov token-estimering: ~4 chars/token engelska. Haiku 4.5 pris:
// $1/M input, $5/M output. Batches API = 50% rabatt = $0.50/$2.50/M.
function estimateCost(articles: Article[]): { input_tokens: number, output_tokens: number, usd: number } {
  let inTok = 0, outTok = 0
  for (const a of articles) {
    inTok  += Math.ceil(buildClassificationPrompt(a).length / 4)
    outTok += 30  // svaret är kort: {"topic":"slug"} ~ 15-25 tokens
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

// Parse topic-slug ur Haiku-JSON. Whitelist mot VALID_TOPICS + 'uncategorized'.
// Ogiltig slug (typo, hallucinerad kategori, ny topic som saknas i taxonomin)
// → null, hamnar som parse_error i outcome-listan.
function parseTopicResult(txt: string): string | null {
  let t = txt.trim().replace(/^```json\s*/, '').replace(/^```\s*/, '').replace(/```[\s\S]*$/, '').trim()
  try {
    const j = JSON.parse(t)
    const v = j?.topic
    if (typeof v !== 'string') return null
    const slug = v.trim().toLowerCase()
    if (!VALID_TOPIC_SET.has(slug as any)) return null
    return slug
  } catch (_) {
    return null
  }
}

// ── Steg 8: EXPLICIT SINGLE-COLUMN UPDATE ───────────────────────────────────
// Ändra INTE denna till upsert-full-object. Se header-kommentaren §KRITISK
// BEGRÄNSNING. Kolumnnamnet är hardkodat och grep-bart.
async function writeTopicOnly(id: string, newTopic: string): Promise<{ ok: true } | { ok: false, reason: string }> {
  const res = await sbFetch(`articles?id=eq.${id}`, {
    method: 'PATCH',
    headers: { 'Prefer': 'return=minimal' },
    // Enda kolumnen som skrivs.
    body: JSON.stringify({ topic: newTopic }),
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
  before: string
  after: string | null
  status: 'changed' | 'unchanged' | 'haiku_error' | 'parse_error' | 'db_error'
  reason?: string
}

function esc(s: string): string {
  return s.replace(/\|/g, '\\|').replace(/\r?\n/g, ' ').slice(0, 120)
}

async function writeReport(
  outcomes: RowOutcome[],
  meta: { batchId: string, mode: 'dry-run' | 'apply', started: string, completed: string, pop: number },
): Promise<void> {
  try { await Deno.mkdir('out', { recursive: true }) } catch (_) {}

  const changed   = outcomes.filter(o => o.status === 'changed')
  const unchanged = outcomes.filter(o => o.status === 'unchanged')
  const haikuErr  = outcomes.filter(o => o.status === 'haiku_error')
  const parseErr  = outcomes.filter(o => o.status === 'parse_error')
  const dbErr     = outcomes.filter(o => o.status === 'db_error')

  // Fördelning per target-topic (bland de som fick ett svar)
  const targetDist = new Map<string, number>()
  for (const o of outcomes) {
    if (o.after) targetDist.set(o.after, (targetDist.get(o.after) ?? 0) + 1)
  }
  const distEntries = [...targetDist.entries()].sort((a, b) => b[1] - a[1])

  let md = `# Topic-classify report — ${meta.completed.slice(0, 10)}

## Meta
| | |
|---|---|
| Batch id | \`${meta.batchId}\` |
| Mode | **${meta.mode}** |
| Prompt | v2026-08-25 (ORDER 153 v1, locally frozen in \`batch-topic-classify.ts\`) |
| Column written | \`topic\` (single-column UPDATE) |
| Population | ${meta.pop.toLocaleString()} rows |
| Started | ${meta.started} |
| Completed | ${meta.completed} |

## Summary
| Metric | Count |
|---|---|
| Rows processed | ${outcomes.length.toLocaleString()} |
| Changed (topic differs from 'uncategorized') | ${changed.length.toLocaleString()} |
| Unchanged (Haiku returned 'uncategorized') | ${unchanged.length.toLocaleString()} |
| Haiku errored | ${haikuErr.length.toLocaleString()} |
| Parse errored (invalid slug) | ${parseErr.length.toLocaleString()} |
| DB errored | ${dbErr.length.toLocaleString()} |

## Distribution (new topic)
| Topic | Count | Share |
|---|---:|---:|
`
  for (const [t, n] of distEntries) {
    const share = (n / outcomes.length * 100).toFixed(1) + '%'
    md += `| ${t} | ${n} | ${share} |\n`
  }

  if (parseErr.length || haikuErr.length || dbErr.length) {
    md += `\n## Errors (first 50)\n| id | status | reason |\n|---|---|---|\n`
    const errs = [...haikuErr, ...parseErr, ...dbErr].slice(0, 50)
    for (const e of errs) md += `| \`${e.id.slice(0, 8)}\` | ${e.status} | ${esc(e.reason || '')} |\n`
  }

  md += `\n## Per-row diff (all ${outcomes.length.toLocaleString()} rows, grouped by new topic)\n\n`
  md += `| id | title | journal | before | after | status |\n`
  md += `|---|---|---|---|---|---|\n`

  const sorted = [...outcomes].sort((a, b) => {
    const at = a.after || 'zzz'   // parse_error / haiku_error last
    const bt = b.after || 'zzz'
    if (at !== bt) return at.localeCompare(bt)
    return a.id.localeCompare(b.id)
  })
  for (const o of sorted) {
    md += `| \`${o.id.slice(0, 8)}\` | ${esc(o.title)} | ${esc(o.journal)} | ${o.before} | ${o.after ?? '—'} | ${o.status} |\n`
  }

  await Deno.writeTextFile(REPORT_PATH, md)
  console.log(`\nReport written: ${REPORT_PATH} (${(md.length / 1024).toFixed(1)} KB, ${outcomes.length.toLocaleString()} rows)`)
}

// ── SAMPLE MODE (live Haiku, ingen batch, inga DB-writes) ──────────────────
const SAMPLE_RATE_LIMIT_MS = 200

async function liveHaikuCall(art: Article): Promise<string | null> {
  const prompt = buildClassificationPrompt(art)
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
    const topic = parseTopicResult(txt)
    if (topic === null) {
      console.error(`  [${art.id.slice(0, 8)}] parse-fail: ${txt.slice(0, 120)}`)
    }
    return topic
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

  const shuffled = [...pop]
  for (let i = shuffled.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1))
    ;[shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]]
  }
  const sample = shuffled.slice(0, Math.min(n, shuffled.length))
  console.log(`Sampling ${sample.length} articles.`)
  console.log(`Est. wall-time: ~${Math.ceil(sample.length * 2.5)}s\n`)

  type SampleRow = { art: Article, after: string | null }
  const results: SampleRow[] = []

  console.log(`  #  BEFORE          AFTER                    TITLE`)
  console.log(`  ─  ──────────────  ───────────────────────  ─────`)

  for (let i = 0; i < sample.length; i++) {
    const art = sample[i]
    const after = await liveHaikuCall(art)
    results.push({ art, after })

    const idx    = String(i + 1).padStart(3)
    const before = art.topic_before.padEnd(14)
    const afterS = (after ?? '(parse-fail)').padEnd(23)
    const title  = (art.title || '(no title)').slice(0, 80)
    console.log(`  ${idx}  ${before}  ${afterS}  ${title}`)

    if (i < sample.length - 1) await new Promise(r => setTimeout(r, SAMPLE_RATE_LIMIT_MS))
  }

  // Summary
  const withAfter = results.filter(r => r.after !== null)
  const err       = results.length - withAfter.length
  const topicDist = new Map<string, number>()
  for (const r of withAfter) topicDist.set(r.after!, (topicDist.get(r.after!) ?? 0) + 1)

  console.log(`\n─── SUMMARY ───`)
  console.log(`  Sampled:     ${sample.length}`)
  console.log(`  Haiku ok:    ${withAfter.length}`)
  console.log(`  Haiku err:   ${err}`)
  console.log(`\n  New topic distribution:`)
  for (const [t, n] of [...topicDist.entries()].sort((a, b) => b[1] - a[1])) {
    console.log(`    ${n.toString().padStart(4)}  ${t}`)
  }
  console.log(`\nDone. No DB writes were made.`)
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
    const before = art?.topic_before ?? 'uncategorized'
    const meta = { id, title: art?.title || '', journal: art?.journal || '', before }

    if (r.result.type !== 'succeeded' || !r.result.message) {
      outcomes.push({ ...meta, after: null, status: 'haiku_error', reason: `${r.result.type}: ${r.result.error?.message || 'unknown'}` })
      continue
    }
    const txt = r.result.message.content?.[0]?.text || ''
    const newTopic = parseTopicResult(txt)
    if (newTopic === null) {
      outcomes.push({ ...meta, after: null, status: 'parse_error', reason: `parse: ${txt.slice(0, 120)}` })
      continue
    }

    // Ingen ändring: Haiku sa 'uncategorized' — samma som before, skriv inte.
    if (newTopic === before) {
      outcomes.push({ ...meta, after: newTopic, status: 'unchanged' })
      continue
    }

    if (apply) {
      const w = await writeTopicOnly(id, newTopic)
      if (!w.ok) {
        outcomes.push({ ...meta, after: newTopic, status: 'db_error', reason: w.reason })
        continue
      }
      written++
      if (written % 500 === 0) console.log(`  Wrote ${written}`)
      await new Promise(res => setTimeout(res, DB_WRITE_RATE_MS))
    }
    outcomes.push({ ...meta, after: newTopic, status: 'changed' })
  }
  if (apply) console.log(`  Wrote ${written} total`)
  return outcomes
}

async function main() {
  const args = parseArgs()
  requireEnv()

  const startedAt = new Date().toISOString()

  if (args.sample !== undefined) {
    await sampleFlow(args.sample)
    return
  }

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

  console.log(`Fetching population (topic = 'uncategorized' AND irrelevant IS NOT TRUE)...`)
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

  console.log(`\nAbout to submit ${requests.length} Haiku batch requests and UPDATE`)
  console.log(`articles.topic on up to ${requests.length.toLocaleString()} rows.`)
  console.log(`No other columns will be touched. Backup exists in topic_backup.`)
  console.log(`Continue? (yes/no)`)
  const buf = new Uint8Array(1024)
  const nread = await Deno.stdin.read(buf)
  const answer = new TextDecoder().decode(buf.subarray(0, nread || 0)).trim().toLowerCase()
  if (answer !== 'yes') {
    console.log('Aborted.')
    return
  }

  console.log('Submitting batch...')
  const batchId = await submitBatch(requests)
  console.log(`  Batch submitted: ${batchId}`)

  const statePath = `${STATE_DIR}/batch-topic-classify-${batchId}.state.json`
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
