// scripts/reclassify-report-round4.ts
// ────────────────────────────────────────────────────────────────────────────
// Skriver rapport för ORDER 147:s topic-reklassificering av uncategorized.
// Läser public.topic_reclassify_log för batch_id 'ORDER-147-round4-
// uncategorized-2026-08-24' + joinar articles för title/journal.
//
// Mönster från scripts/batch-regen-sci.ts (writeReport-funktionen): meta-
// block + summary + distribution + per-row diff sorted by topic-flow.
//
// KÖRS EFTER 20260824140000_apply_topic_reclassify_round4.sql. Ingen DB-
// skrivning — bara SELECT + filsystem-write till out/.
//
// USAGE:
//   export SUPABASE_URL=https://igmkzhdovyhbfgjomrsc.supabase.co
//   export SERVICE_ROLE_KEY=<key>
//   deno run --allow-net --allow-env --allow-write=out \
//     scripts/reclassify-report-round4.ts
//
// FLAGGOR:
//   --batch-id=<id>   default 'ORDER-147-round4-uncategorized-2026-08-24'
//   --out=<path>      default 'out/reclassify-uncategorized-round4.md'
// ────────────────────────────────────────────────────────────────────────────

const SB_URL = Deno.env.get('SUPABASE_URL') || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_KEY = Deno.env.get('SERVICE_ROLE_KEY') || ''
if (!SB_KEY) {
  console.error('SERVICE_ROLE_KEY env-var saknas')
  Deno.exit(2)
}

const args = Deno.args
const getArg = (name: string, def = ''): string => {
  const a = args.find(x => x.startsWith(`--${name}=`))
  return a ? a.split('=').slice(1).join('=') : def
}

const BATCH_ID    = getArg('batch-id', 'ORDER-147-round4-uncategorized-2026-08-24')
const REPORT_PATH = getArg('out',      'out/reclassify-uncategorized-round4.md')

// PostgREST paginerar med Range-header. topic_reclassify_log kan innehålla
// ~3,447 rader för denna batch — långt under default-cap på 1000; hämta i
// pages om 1000 för säkerhets skull.
const PAGE = 1000

type LogRow = {
  id: number
  article_id: string
  old_topic: string
  new_topic: string
  matched_kw: string[]
  applied_at: string
  articles?: {
    title: string | null
    journal: string | null
  } | null
}

async function fetchPage(offset: number, limit: number): Promise<LogRow[]> {
  // Nested resource-embedding via PostgREST:
  // /topic_reclassify_log?select=id,article_id,old_topic,new_topic,matched_kw,applied_at,articles(title,journal)
  const url = new URL(`${SB_URL}/rest/v1/topic_reclassify_log`)
  url.searchParams.set('select', 'id,article_id,old_topic,new_topic,matched_kw,applied_at,articles(title,journal)')
  url.searchParams.set('batch_id', `eq.${BATCH_ID}`)
  url.searchParams.set('order', 'id.asc')
  const r = await fetch(url.toString(), {
    headers: {
      apikey: SB_KEY,
      Authorization: `Bearer ${SB_KEY}`,
      Range: `${offset}-${offset + limit - 1}`,
      'Range-Unit': 'items',
      Prefer: 'count=exact',
    },
  })
  if (!r.ok) {
    throw new Error(`HTTP ${r.status}: ${(await r.text()).slice(0, 300)}`)
  }
  return await r.json() as LogRow[]
}

async function fetchAll(): Promise<LogRow[]> {
  const all: LogRow[] = []
  let offset = 0
  while (true) {
    const page = await fetchPage(offset, PAGE)
    all.push(...page)
    if (page.length < PAGE) break
    offset += PAGE
  }
  return all
}

function esc(s: string | null | undefined): string {
  if (!s) return ''
  return s.replace(/\|/g, '\\|').replace(/\n/g, ' ').slice(0, 180)
}

function fmt(n: number): string { return n.toLocaleString('en-US') }

async function main() {
  console.log(`\nBatch id:  ${BATCH_ID}`)
  console.log(`SB URL:    ${SB_URL}`)
  console.log(`Report:    ${REPORT_PATH}\n`)

  const started = new Date().toISOString()
  console.log('Hämtar rader ur topic_reclassify_log...')
  const rows = await fetchAll()
  console.log(`  ${rows.length} rader hämtade\n`)

  if (rows.length === 0) {
    console.error(`Inga rader i topic_reclassify_log för batch_id='${BATCH_ID}'.`)
    console.error('Har apply-migrationen körts?')
    Deno.exit(1)
  }

  // ── Distributioner ─────────────────────────────────────────────────────────
  const byOld = new Map<string, number>()
  const byNew = new Map<string, number>()
  const kwHits = new Map<string, number>()  // hur ofta varje kw dök upp
  const flowCounts = new Map<string, number>()  // 'old → new' → count

  for (const r of rows) {
    byOld.set(r.old_topic, (byOld.get(r.old_topic) ?? 0) + 1)
    byNew.set(r.new_topic, (byNew.get(r.new_topic) ?? 0) + 1)
    const flow = `${r.old_topic} → ${r.new_topic}`
    flowCounts.set(flow, (flowCounts.get(flow) ?? 0) + 1)
    for (const kw of (r.matched_kw || [])) {
      kwHits.set(kw, (kwHits.get(kw) ?? 0) + 1)
    }
  }

  // Sorterade view-lists
  const newTopicRows = [...byNew.entries()].sort((a, b) => b[1] - a[1])
  const topKw        = [...kwHits.entries()].sort((a, b) => b[1] - a[1]).slice(0, 40)
  const applied_at   = rows.length > 0 ? rows[0].applied_at : started

  // ── Markdown-rapport ───────────────────────────────────────────────────────
  let md = `# Topic reclassification report — round 4 (${applied_at.slice(0, 10)})

## Meta
| | |
|---|---|
| Batch id | \`${BATCH_ID}\` |
| Migration | \`20260824140000_apply_topic_reclassify_round4.sql\` |
| Scenario | D (keywords + title, min 2 hits OR (1 hit + kw_len ≥ 3)) |
| Population | 7,574 (uncategorized non-irrelevant med keywords) |
| Applied at | ${applied_at} |
| Report generated | ${started} |

## Summary
| Metric | Count |
|---|---|
| Rows moved out of uncategorized | ${fmt(rows.length)} |
| Distinct target topics | ${byNew.size} |
| Distinct matched keywords | ${kwHits.size} |

## Distribution (destination topic)
| new_topic | count | share |
|---|---:|---:|
`
  for (const [t, c] of newTopicRows) {
    const share = (c / rows.length * 100).toFixed(1) + '%'
    md += `| ${t} | ${fmt(c)} | ${share} |\n`
  }

  md += `\n## Top 40 matched keywords\n`
  md += `| keyword | hits |\n|---|---:|\n`
  for (const [kw, n] of topKw) {
    md += `| \`${kw}\` | ${fmt(n)} |\n`
  }

  md += `\n## Per-row diff (all ${fmt(rows.length)} rows, grouped by new_topic)\n\n`
  md += `| id | title | journal | old_topic | new_topic | matched_kw |\n`
  md += `|---|---|---|---|---|---|\n`

  // Sortera: new_topic asc → applied_at asc för läsbar gruppering
  const sorted = [...rows].sort((a, b) => {
    if (a.new_topic !== b.new_topic) return a.new_topic.localeCompare(b.new_topic)
    return a.id - b.id
  })
  for (const r of sorted) {
    const title   = esc(r.articles?.title || '')
    const journal = esc(r.articles?.journal || '')
    const matched = esc((r.matched_kw || []).join(', '))
    md += `| \`${r.article_id.slice(0, 8)}\` | ${title} | ${journal} | ${r.old_topic} | ${r.new_topic} | ${matched} |\n`
  }

  // Säkra att out/ finns
  try { await Deno.mkdir('out', { recursive: true }) } catch (_) {}
  await Deno.writeTextFile(REPORT_PATH, md)

  console.log(`Rapport skriven till ${REPORT_PATH} (${fmt(md.length)} bytes)`)
  console.log(`  ${fmt(rows.length)} rader, ${byNew.size} target topics, ${kwHits.size} distinkta kw`)
  console.log(`  top-mottagare: ${newTopicRows.slice(0, 3).map(([t, c]) => `${t} (${fmt(c)})`).join(', ')}`)
}

main().catch(e => { console.error(e); Deno.exit(1) })
