// scripts/recover-parse-errors.ts
//
// ORDER 154 (2026-08-25) — parse-error rescue för ORDER 153.
//
// KONTEXT
// -------
// Batch-topic-classify:s parser krävde att hela Haiku-svaret var ett
// välformat JSON-objekt. Haiku 4.5 lade ibland till "Reasoning:"-fri-
// text efter JSON-blocket, vilket JSON.parse rejectade → 116 rader
// stannade i `uncategorized` trots att modellen faktiskt hade svarat.
//
// Detta script räddar dem UTAN ny AI-körning:
//   1. Hittar de 116 parse_error-id:na i out/topic-classify.md.
//   2. Hämtar råtexten på Haikus svar via en av två vägar:
//        --from-report  (default) → parsar reason-strängen i rapportens
//                                    "Errors"-sektion. Rapporten kappar
//                                    dock den sektionen till första 50,
//                                    så det räcker som mest till 50/116.
//        --refetch --batch <id>   → laddar hela JSONL från Anthropic
//                                    batch-results-URL. Täcker alla 116.
//                                    Kräver ANTHROPIC_API_KEY. Detta är
//                                    en gratis nedladdning av redan
//                                    körda resultat — INGEN ny inferens.
//   3. Extraherar topic-slugen med samma tolerans-parser som fixen i
//      batch-topic-classify.ts (accepterar efterföljande text).
//   4. Validerar mot VALID_TOPIC_SET.
//   5. Rapporterar antal räddningsbara + topic-fördelning.
//   6. Med --apply: PATCH articles.topic för varje räddad rad.
//      Utan --apply: dry-run, inga skrivningar.
//
// BACKUP: topic_backup från ORDER 153 (migration 20260825130000) täcker
// dessa rader redan. Ingen ny migration behövs.
//
// ANVÄNDNING
// ----------
//   deno run --allow-net --allow-env --allow-read \
//     scripts/recover-parse-errors.ts                        # dry-run från rapport
//   deno run --allow-net --allow-env --allow-read \
//     scripts/recover-parse-errors.ts --refetch              # dry-run + full täckning
//   deno run --allow-net --allow-env --allow-read \
//     scripts/recover-parse-errors.ts --refetch --apply      # skriv till DB
//
// MILJÖ
// -----
//   ANTHROPIC_API_KEY          — endast för --refetch
//   SUPABASE_URL               — default: prod-URL
//   SUPABASE_SERVICE_ROLE_KEY  — krävs för --apply (och för prefix→uuid-lookup)

const REPORT_PATH = 'out/topic-classify.md'

const SB_URL = Deno.env.get('SUPABASE_URL') || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') || ''

// Håll listan i sync med batch-topic-classify.ts:s VALID_TOPICS.
const VALID_TOPICS = [
  'food_science', 'fermentation_science', 'sensory_evaluation',
  'flavor_science', 'food_psychology', 'nutritional_science',
  'hospitality', 'food_anthropology', 'gastronomy', 'sommellerie',
  'appetite_research', 'culinary_science', 'multisensory',
  'atmospherics', 'culinary_education', 'novel_foods', 'art_science',
  'experiential_dining', 'food_pairing', 'food_behavior',
  'food_technology', 'servicescape', 'molecular_mixology',
  'crossmodal', 'sensory_training', 'neurogastronomy',
  'uncategorized',
] as const
const VALID_TOPIC_SET = new Set<string>(VALID_TOPICS)

// ── CLI ──
const args = Deno.args
const apply = args.includes('--apply')
const refetch = args.includes('--refetch')
let batchIdArg = ''
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--batch' && args[i + 1]) batchIdArg = args[i + 1]
}

// ── TOLERANT PARSER (identisk med fix i batch-topic-classify.ts) ──
// Steg: strippa ```json-code-fences → försök JSON.parse hela strängen →
// om det failar, extrahera första balanserade {...}-blocket → om ÄVEN
// det failar, regex-extraktion av "topic":"..."-fältet direkt.
function extractFirstJsonObject(s: string): string | null {
  const i = s.indexOf('{')
  if (i < 0) return null
  let depth = 0
  let inStr = false
  let esc = false
  for (let j = i; j < s.length; j++) {
    const c = s[j]
    if (esc) { esc = false; continue }
    if (c === '\\') { esc = true; continue }
    if (c === '"') { inStr = !inStr; continue }
    if (inStr) continue
    if (c === '{') depth++
    else if (c === '}') {
      depth--
      if (depth === 0) return s.slice(i, j + 1)
    }
  }
  return null
}

function parseTopicResult(txt: string): string | null {
  const t = txt.trim().replace(/^```json\s*/, '').replace(/^```\s*/, '').replace(/```[\s\S]*$/, '').trim()
  let obj: any = null
  try { obj = JSON.parse(t) } catch (_) { /* fallthrough */ }
  if (!obj) {
    const objStr = extractFirstJsonObject(t)
    if (objStr) { try { obj = JSON.parse(objStr) } catch (_) { /* fallthrough */ } }
  }
  if (!obj) {
    const m = t.match(/"topic"\s*:\s*"([a-z_]+)"/)
    if (m) obj = { topic: m[1] }
  }
  if (!obj) return null
  const v = obj?.topic
  if (typeof v !== 'string') return null
  const slug = v.trim().toLowerCase()
  if (!VALID_TOPIC_SET.has(slug)) return null
  return slug
}

// ── Rapport-läsning ──
type ReportView = {
  batchId: string
  parseErrPrefixes: string[]       // 8-tecken-prefixes från per-row diff
  reasonByPrefix: Map<string, string>  // finns bara för de 50 i Errors-sektionen
}

async function readReport(): Promise<ReportView> {
  const md = await Deno.readTextFile(REPORT_PATH)
  const batchMatch = md.match(/Batch id \| `([^`]+)`/)
  const batchId = batchMatch ? batchMatch[1] : ''

  const parseErrPrefixes: string[] = []
  const reasonByPrefix = new Map<string, string>()

  const lines = md.split('\n')
  let inPerRow = false
  for (const line of lines) {
    if (line.startsWith('## Per-row diff')) inPerRow = true

    // Errors-sektion: | `id` | parse_error | parse: <text> |
    const errMatch = line.match(/^\|\s*`([0-9a-f]{6,8})`\s*\|\s*parse_error\s*\|\s*parse:\s*(.+?)\s*\|\s*$/)
    if (errMatch && !inPerRow) {
      reasonByPrefix.set(errMatch[1], errMatch[2])
      continue
    }
    // Per-row: | `id` | title | journal | before | after | parse_error |
    if (inPerRow && line.includes('| parse_error |')) {
      const m = line.match(/^\|\s*`([0-9a-f]{6,8})`\s*\|/)
      if (m) parseErrPrefixes.push(m[1])
    }
  }
  return { batchId, parseErrPrefixes, reasonByPrefix }
}

// ── Anthropic batch-refetch ──
async function refetchBatchResponses(batchId: string): Promise<Map<string, string>> {
  if (!ANTHROPIC_KEY) throw new Error('ANTHROPIC_API_KEY not set (behövs för --refetch)')
  const stRes = await fetch(`https://api.anthropic.com/v1/messages/batches/${batchId}`, {
    headers: { 'x-api-key': ANTHROPIC_KEY, 'anthropic-version': '2023-06-01' },
  })
  if (!stRes.ok) throw new Error(`batch status: HTTP ${stRes.status} ${(await stRes.text()).slice(0, 200)}`)
  const st = await stRes.json()
  if (!st.results_url) throw new Error(`batch has no results_url (status=${st.processing_status ?? 'unknown'})`)

  const resRes = await fetch(st.results_url, {
    headers: { 'x-api-key': ANTHROPIC_KEY, 'anthropic-version': '2023-06-01' },
  })
  if (!resRes.ok) throw new Error(`results fetch: HTTP ${resRes.status}`)

  const map = new Map<string, string>()
  for (const line of (await resRes.text()).split('\n').filter(Boolean)) {
    let obj: any
    try { obj = JSON.parse(line) } catch { continue }
    const id = obj?.custom_id
    const text = obj?.result?.message?.content?.[0]?.text
    if (typeof id === 'string' && typeof text === 'string') map.set(id, text)
  }
  return map
}

// ── Supabase helpers ──
function sbHeaders(): Record<string, string> {
  return {
    'apikey': SB_KEY,
    'Authorization': `Bearer ${SB_KEY}`,
    'Content-Type': 'application/json',
  }
}

// Prefix→full-uuid-lookup (bara nödvändig när vi kör från rapport och
// bara har 8-tecken-prefix). Batchar för att inte spamma PostgREST.
async function resolvePrefixesToFullIds(prefixes: string[]): Promise<Map<string, string>> {
  if (!SB_KEY) throw new Error('SUPABASE_SERVICE_ROLE_KEY not set (behövs för prefix→uuid-lookup)')
  const map = new Map<string, string>()
  const chunkSize = 50
  for (let i = 0; i < prefixes.length; i += chunkSize) {
    const chunk = prefixes.slice(i, i + chunkSize)
    const or = chunk.map(p => `id.like.${p}*`).join(',')
    const url = `${SB_URL}/rest/v1/articles?select=id&or=(${encodeURIComponent(or)})`
    const res = await fetch(url, { headers: sbHeaders() })
    if (!res.ok) throw new Error(`prefix lookup: HTTP ${res.status} ${(await res.text()).slice(0, 200)}`)
    const rows: { id: string }[] = await res.json()
    for (const r of rows) {
      const pref = r.id.slice(0, 8)
      if (chunk.includes(pref)) map.set(pref, r.id)
    }
  }
  return map
}

async function writeTopicOnly(fullId: string, topic: string): Promise<{ ok: true } | { ok: false, reason: string }> {
  const res = await fetch(`${SB_URL}/rest/v1/articles?id=eq.${fullId}`, {
    method: 'PATCH',
    headers: { ...sbHeaders(), 'Prefer': 'return=minimal' },
    body: JSON.stringify({ topic }),
  })
  if (!res.ok) return { ok: false, reason: `db ${res.status}: ${(await res.text()).slice(0, 200)}` }
  return { ok: true }
}

// ── Main ──
async function main() {
  console.log(`Reading ${REPORT_PATH}...`)
  const view = await readReport()
  console.log(`  batch id             : ${view.batchId || '(not found)'}`)
  console.log(`  parse_error rows     : ${view.parseErrPrefixes.length}`)
  console.log(`  reasons in report    : ${view.reasonByPrefix.size} (rapporten kappar Errors-sektionen till första 50)`)

  // Bygg responsMap: prefix → full Haiku-svar
  const responsesByPrefix = new Map<string, string>()
  const responsesByFullId = new Map<string, string>()

  if (refetch) {
    const batchId = batchIdArg || view.batchId
    if (!batchId) { console.error('Ingen batch id (använd --batch <id>)'); Deno.exit(2) }
    console.log(`\nRefetching batch ${batchId} från Anthropic (endast nedladdning, inga nya inferenser)...`)
    const full = await refetchBatchResponses(batchId)
    console.log(`  fetched ${full.size} raw responses`)
    for (const [fullId, txt] of full.entries()) {
      responsesByFullId.set(fullId, txt)
      responsesByPrefix.set(fullId.slice(0, 8), txt)
    }
  } else {
    for (const [pref, txt] of view.reasonByPrefix.entries()) responsesByPrefix.set(pref, txt)
  }

  // Klassificera varje prefix
  type Candidate = { prefix: string, topic: string }
  const validated: Candidate[] = []
  const stayedUncat: string[] = []       // Haiku sa uncategorized — samma som "before"
  const noResponse: string[] = []        // ingen text i rapporten (troligt för 66 utan reason)
  const stillBad: string[] = []          // parsern kunde inte extrahera trots ny logik

  for (const pref of view.parseErrPrefixes) {
    const txt = responsesByPrefix.get(pref)
    if (!txt) { noResponse.push(pref); continue }
    const t = parseTopicResult(txt)
    if (t === null) { stillBad.push(pref); continue }
    if (t === 'uncategorized') { stayedUncat.push(pref); continue }
    validated.push({ prefix: pref, topic: t })
  }

  // Topic-fördelning
  const dist = new Map<string, number>()
  for (const { topic } of validated) dist.set(topic, (dist.get(topic) ?? 0) + 1)
  const sorted = [...dist.entries()].sort((a, b) => b[1] - a[1])

  console.log(`\n=== Rescue summary (${apply ? 'APPLY' : 'DRY-RUN'}) ===`)
  console.log(`Rows in parse_error residual : ${view.parseErrPrefixes.length}`)
  console.log(`Responses available          : ${responsesByPrefix.size}`)
  console.log(`  → validated & will rescue  : ${validated.length}`)
  console.log(`  → returned "uncategorized" : ${stayedUncat.length}  (no write needed)`)
  console.log(`  → still unparseable        : ${stillBad.length}`)
  console.log(`No response for prefix       : ${noResponse.length}  ${refetch ? '' : '(→ kör --refetch för full täckning)'}`)

  if (sorted.length > 0) {
    console.log(`\nTopic distribution among validated:`)
    for (const [t, n] of sorted) console.log(`  ${t.padEnd(24)} ${n}`)
  }

  if (!apply) {
    console.log(`\n[dry-run] Inga DB-skrivningar. Kör om med --apply för att skriva.`)
    return
  }

  // ── Apply-vägen ──
  if (validated.length === 0) {
    console.log(`\nInga rader att skriva. Klart.`)
    return
  }
  if (!SB_KEY) { console.error('SUPABASE_SERVICE_ROLE_KEY not set — kan inte skriva'); Deno.exit(3) }

  // Lös prefix → full uuid
  console.log(`\nResolving ${validated.length} prefixes → full article ids...`)
  const prefixToFull = refetch
    ? new Map<string, string>(
        [...responsesByFullId.keys()].map(id => [id.slice(0, 8), id]),
      )
    : await resolvePrefixesToFullIds(validated.map(v => v.prefix))

  const toWrite: { fullId: string, topic: string, prefix: string }[] = []
  const missingFull: string[] = []
  for (const v of validated) {
    const full = prefixToFull.get(v.prefix)
    if (!full) { missingFull.push(v.prefix); continue }
    toWrite.push({ fullId: full, topic: v.topic, prefix: v.prefix })
  }
  if (missingFull.length) console.log(`  ⚠ ${missingFull.length} prefix hittades inte i articles (utelämnas)`)

  console.log(`\nSkriver ${toWrite.length} rader (topic-kolumnen, inget annat)...`)
  let ok = 0, fail = 0
  for (const w of toWrite) {
    const r = await writeTopicOnly(w.fullId, w.topic)
    if (r.ok) ok++
    else { fail++; console.error(`  [${w.prefix}] FAIL: ${r.reason}`) }
  }
  console.log(`\nWrote: ${ok} OK, ${fail} failed.`)
}

if (import.meta.main) await main()
