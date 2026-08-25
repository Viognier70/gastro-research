// scripts/audit-uncategorized-pubtype.ts
//
// ORDER 155 (2026-08-25) — publikationstyp-audit av uncategorized-residualen.
//
// KONTEXT
// -------
// Efter ORDER 153 (Haiku-klassificering) + ORDER 154 (parse-error rescue)
// har articles.topic='uncategorized' AND irrelevant IS NOT TRUE ~218 rader.
// Beslutet är att uncategorized är OK så länge artikeln är peer-reviewad
// eller på annat sätt en vetenskaplig publikation — allt annat bör
// flaggas irrelevant.
//
// Detta script gör en INVENTERING (inga skrivningar):
//   1. Fältövergripande täckning (study_type, journal, has_imrad, doi,
//      source, source_label) för hela residualen.
//   2. Kategoriserar journal-fältet via strängheuristik:
//        - empty                — journal saknas
//        - book_review          — "Review of Books", "Book Review", etc.
//        - magazine             — "Magazine", "News", "Newsletter"
//        - conference           — "Proceedings", "Conference", "Symposium",
//                                 "Web of Conferences"
//        - preprint_repo        — arXiv, Zenodo, GESIS Repository, SSRN
//        - peer_reviewed_likely — resten (default; kan innehålla predatory)
//   3. Skriver rapport till out/uncategorized-pubtype-audit.md.
//
// ANVÄNDNING
// ----------
//   deno run --allow-net --allow-env --allow-read --allow-write \
//     scripts/audit-uncategorized-pubtype.ts
//
// MILJÖ
// -----
//   SUPABASE_URL               — default: prod-URL
//   SUPABASE_SERVICE_ROLE_KEY  — krävs (RLS bypass för läsning av topic-fält)

const SB_URL = Deno.env.get('SUPABASE_URL') || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''

if (!SB_KEY) {
  console.error('SUPABASE_SERVICE_ROLE_KEY not set')
  Deno.exit(1)
}

const OUT_PATH = 'out/uncategorized-pubtype-audit.md'

type Row = {
  id: string
  title: string | null
  journal: string | null
  url: string | null
  has_doi_url: boolean          // härleds ur url (articles har ingen doi-kolumn)
  source: string | null
  source_label: string | null
  study_type: string | null
  has_imrad: boolean
}

async function fetchUncategorized(): Promise<Row[]> {
  // has_imrad härleds ur imrad_introduction (samma logik som articles_public).
  // articles har ingen doi-kolumn; DOI lagras i url som "https://doi.org/…"
  // (se daily-fetch/index.ts:408, 491, 629). Vi använder url som proxy för
  // DOI-täckning: has_doi_url = url matchar /doi\.org/i.
  const select = 'id,title,journal,url,source,source_label,study_type,imrad_introduction'
  const url = `${SB_URL}/rest/v1/articles?select=${select}&topic=eq.uncategorized&irrelevant=not.is.true&limit=1000`
  const res = await fetch(url, {
    headers: {
      'apikey': SB_KEY,
      'Authorization': `Bearer ${SB_KEY}`,
      'Accept': 'application/json',
    },
  })
  if (!res.ok) throw new Error(`fetch: HTTP ${res.status} ${(await res.text()).slice(0, 200)}`)
  const raw: any[] = await res.json()
  return raw.map(r => ({
    id: r.id,
    title: r.title,
    journal: r.journal,
    url: r.url,
    has_doi_url: !!r.url && /doi\.org/i.test(r.url),
    source: r.source,
    source_label: r.source_label,
    study_type: r.study_type,
    has_imrad: r.imrad_introduction !== null,
  }))
}

type PubType =
  | 'empty'
  | 'book_review'
  | 'magazine'
  | 'conference'
  | 'preprint_repo'
  | 'peer_reviewed_likely'

// Heuristik-regler (case-insensitive, ordning viktig — mer specifika först).
function classifyJournal(j: string | null | undefined): PubType {
  if (!j || j.trim() === '') return 'empty'
  const s = j.toLowerCase()
  if (/\breview of books\b|\bbook review\b/.test(s)) return 'book_review'
  if (/\bmagazine\b|\bnewsletter\b/.test(s)) return 'magazine'
  if (/libraries news\b|\bnews$/.test(s)) return 'magazine'
  if (/\bproceedings\b|\bconference\b|\bsymposium\b|web of conferences\b|\bworkshop\b/.test(s)) return 'conference'
  if (/^arxiv$|^biorxiv$|^ssrn$|zenodo|open access repository|preprints/.test(s)) return 'preprint_repo'
  return 'peer_reviewed_likely'
}

function esc(s: string | null | undefined): string {
  return (s ?? '').replace(/\|/g, '\\|').replace(/\r?\n/g, ' ').slice(0, 140)
}

async function main() {
  console.log(`Fetching uncategorized rows...`)
  const rows = await fetchUncategorized()
  console.log(`  ${rows.length} rows fetched`)

  // ── Täckning ──
  const total = rows.length
  const cov = (pred: (r: Row) => boolean) => rows.filter(pred).length
  const coverage = {
    journal_nonempty : cov(r => !!r.journal && r.journal.trim() !== ''),
    url_nonempty     : cov(r => !!r.url && r.url.trim() !== ''),
    has_doi_url      : cov(r => r.has_doi_url),
    study_type_nonempty: cov(r => !!r.study_type && r.study_type.trim() !== ''),
    has_imrad        : cov(r => r.has_imrad),
    source_nonempty  : cov(r => !!r.source && r.source.trim() !== ''),
  }

  // ── Pubtype-fördelning ──
  const pubDist = new Map<PubType, Row[]>()
  for (const r of rows) {
    const t = classifyJournal(r.journal)
    if (!pubDist.has(t)) pubDist.set(t, [])
    pubDist.get(t)!.push(r)
  }
  const pubOrder: PubType[] = ['peer_reviewed_likely', 'conference', 'preprint_repo', 'magazine', 'book_review', 'empty']

  // ── study_type-fördelning ──
  const stDist = new Map<string, number>()
  for (const r of rows) {
    const k = (r.study_type && r.study_type.trim()) || '(empty)'
    stDist.set(k, (stDist.get(k) ?? 0) + 1)
  }
  const stSorted = [...stDist.entries()].sort((a, b) => b[1] - a[1])

  // ── source-fördelning ──
  const srcDist = new Map<string, number>()
  for (const r of rows) {
    const k = r.source || '(empty)'
    srcDist.set(k, (srcDist.get(k) ?? 0) + 1)
  }
  const srcSorted = [...srcDist.entries()].sort((a, b) => b[1] - a[1])

  // ── Skriv rapport ──
  try { await Deno.mkdir('out', { recursive: true }) } catch (_) {}
  let md = `# Uncategorized publication-type audit — ${new Date().toISOString().slice(0, 10)}\n\n`
  md += `## Meta\n| | |\n|---|---|\n`
  md += `| Population | ${total} rader (topic='uncategorized' AND irrelevant IS NOT TRUE) |\n`
  md += `| Genererat  | ${new Date().toISOString()} |\n\n`

  md += `## Fältövergripande täckning\n| Fält | Non-empty | % |\n|---|---:|---:|\n`
  for (const [k, v] of Object.entries(coverage)) {
    md += `| ${k} | ${v} | ${((v / total) * 100).toFixed(1)}% |\n`
  }
  md += `\n`

  md += `## Publikationstyp (heuristisk på journal-fält)\n| Typ | Antal | % |\n|---|---:|---:|\n`
  for (const t of pubOrder) {
    const n = pubDist.get(t)?.length ?? 0
    md += `| ${t} | ${n} | ${((n / total) * 100).toFixed(1)}% |\n`
  }
  md += `\n`

  md += `## study_type-värden\n| study_type | Antal |\n|---|---:|\n`
  for (const [k, n] of stSorted) md += `| ${k} | ${n} |\n`
  md += `\n`

  md += `## source-värden\n| source | Antal |\n|---|---:|\n`
  for (const [k, n] of srcSorted) md += `| ${k} | ${n} |\n`
  md += `\n`

  for (const t of pubOrder) {
    const list = pubDist.get(t) ?? []
    if (list.length === 0) continue
    md += `## Rader klassade som \`${t}\` (${list.length})\n`
    md += `| id | title | journal | study_type | has_imrad | doi_url |\n`
    md += `|---|---|---|---|:-:|:-:|\n`
    for (const r of list.sort((a, b) => (a.journal || '').localeCompare(b.journal || ''))) {
      md += `| \`${r.id.slice(0, 8)}\` | ${esc(r.title)} | ${esc(r.journal)} | ${r.study_type || '—'} | ${r.has_imrad ? '✓' : '—'} | ${r.has_doi_url ? '✓' : '—'} |\n`
    }
    md += `\n`
  }

  await Deno.writeTextFile(OUT_PATH, md)
  console.log(`\nReport written: ${OUT_PATH}`)

  // Snabbsummary till stdout
  console.log(`\n=== Coverage ===`)
  for (const [k, v] of Object.entries(coverage)) console.log(`  ${k.padEnd(22)} ${v.toString().padStart(4)}  ${((v / total) * 100).toFixed(1)}%`)
  console.log(`\n=== Pubtype ===`)
  for (const t of pubOrder) console.log(`  ${t.padEnd(22)} ${(pubDist.get(t)?.length ?? 0).toString().padStart(4)}`)
}

if (import.meta.main) await main()
