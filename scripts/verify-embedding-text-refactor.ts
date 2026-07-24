// verify-embedding-text-refactor.ts
// ─────────────────────────────────────────────────────────────────────────────
// ENGÅNGSVERIFIERING: bevisa byte-identity mellan legacy inline-textbyggare
// (supabase/functions/generate-embeddings/index.ts:54-60 FÖRE refaktoreringen)
// och den refaktorerade buildEmbeddingText() i _shared/embedding-text.ts.
//
// KRAV: 200/200 identiska. Vid någon diff — rapportera första, med båda
// strängar och index för första avvikande tecken. Ingen deploy av refaktorn
// förrän scriptet passerar rent.
//
// URVAL: 200 slumpade artiklar från embedding-populationen, garanterat
// inkluderar minst:
//   - 10 artiklar med minst ett episteme-fält som NULL (filter(Boolean)-test)
//   - 5 artiklar med totallängd > TEXT_SLICE (slice-test)
// (Om DB inte har så många i respektive kategori: rapportera hur många.)
//
// Kör:
//   deno run --allow-net --allow-env \
//     scripts/verify-embedding-text-refactor.ts
//
// ENV: SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY (samma som edge-fn:en).
// ─────────────────────────────────────────────────────────────────────────────

import { buildEmbeddingText, EMBEDDING_COLUMNS, TEXT_SLICE, type EmbeddingSource } from '../supabase/functions/_shared/embedding-text.ts'

const SB_URL = Deno.env.get('SUPABASE_URL') || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''

if (!SB_KEY) {
  console.error('Missing SUPABASE_SERVICE_ROLE_KEY')
  Deno.exit(2)
}

type Row = EmbeddingSource & { id: string }

// ── LEGACY INLINE — ordagrann kopia av generate-embeddings/index.ts:54-60
// FÖRE refaktoreringen 2026-07-24. RÖR INTE — det är detta som ska bevisas
// byte-identiskt med buildEmbeddingText.
// ─────────────────────────────────────────────────────────────────────────────
const LEGACY_TEXT_SLICE = 8000

function legacyInline(a: Row): string {
  const t = [
    a.title, a.core_claim, a.topic,
    a.episteme_sensory_pro, a.episteme_culinary_pro, a.episteme_gastronomy_culture,
    a.episteme_hospitality_mgmt, a.episteme_educator_researcher
  ].filter(Boolean).join(' ').slice(0, LEGACY_TEXT_SLICE)
  return t
}

// ── Sanity: TEXT_SLICE ska vara identisk mellan gammal och ny ────────────────
if (TEXT_SLICE !== LEGACY_TEXT_SLICE) {
  console.error(`TEXT_SLICE drift: legacy=${LEGACY_TEXT_SLICE}, ny=${TEXT_SLICE}`)
  Deno.exit(3)
}

const FETCH_COLS = 'id,title,core_claim,topic,' +
  'episteme_sensory_pro,episteme_culinary_pro,episteme_gastronomy_culture,' +
  'episteme_hospitality_mgmt,episteme_educator_researcher'

// ── DB-hämtning ──────────────────────────────────────────────────────────────
async function sbFetch(path: string): Promise<Response> {
  return await fetch(`${SB_URL}/rest/v1/${path}`, {
    headers: {
      'apikey': SB_KEY,
      'Authorization': `Bearer ${SB_KEY}`,
    },
  })
}

async function fetchRandom(n: number): Promise<Row[]> {
  // PostgREST har inget ORDER BY random() out-of-the-box — men vi kan slumpa
  // en offset i den kvalificerade populationen. För verifiering räcker en
  // deterministisk-men-varierad slice: skanna en overshoot och skaka lokalt.
  const cols = FETCH_COLS
  const overshoot = n * 20   // hämta större pool så vi kan handplocka NULL/long-fall
  const res = await sbFetch(
    `articles?select=${cols}&episteme_sensory_pro=not.is.null&limit=${overshoot}`
  )
  if (!res.ok) {
    console.error(`Fetch failed: HTTP ${res.status} ${(await res.text()).slice(0, 200)}`)
    Deno.exit(4)
  }
  const pool = await res.json() as Row[]
  // Fisher-Yates
  for (let i = pool.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1))
    ;[pool[i], pool[j]] = [pool[j], pool[i]]
  }
  return pool.slice(0, n)
}

async function fetchNullCases(n: number): Promise<Row[]> {
  // Artiklar där något episteme-fält utöver sensory_pro är NULL — testar
  // filter(Boolean). sensory_pro kan inte vara NULL pga edge-fn:ens filter,
  // men culinary/gastronomy/hospitality/educator kan vara det.
  const cols = FETCH_COLS
  const res = await sbFetch(
    `articles?select=${cols}&episteme_sensory_pro=not.is.null&episteme_educator_researcher=is.null&limit=${n}`
  )
  if (!res.ok) return []
  return await res.json() as Row[]
}

async function fetchLongCases(n: number): Promise<Row[]> {
  // Artiklar där totallängden garanterat > TEXT_SLICE = 8000 — testar slice.
  // Approximation: sortera efter längd på episteme_educator_researcher desc.
  // Om PostgREST inte kan sortera på length: hämta mycket och filtrera lokalt.
  const cols = FETCH_COLS
  const res = await sbFetch(
    `articles?select=${cols}&episteme_sensory_pro=not.is.null&episteme_educator_researcher=not.is.null&limit=200`
  )
  if (!res.ok) return []
  const pool = await res.json() as Row[]
  const long = pool
    .map(r => ({ r, len: legacyInline(r).length }))
    .filter(x => x.len > TEXT_SLICE)
    .sort((a, b) => b.len - a.len)
    .slice(0, n)
    .map(x => x.r)
  return long
}

// ── Jämförelse ───────────────────────────────────────────────────────────────
function firstDiff(a: string, b: string): number {
  const min = Math.min(a.length, b.length)
  for (let i = 0; i < min; i++) if (a.charCodeAt(i) !== b.charCodeAt(i)) return i
  if (a.length !== b.length) return min
  return -1
}

function showContext(s: string, at: number): string {
  const start = Math.max(0, at - 30)
  const end = Math.min(s.length, at + 30)
  return `…${s.slice(start, at)}【${s.slice(at, at + 1)}】${s.slice(at + 1, end)}…`
}

// ── Main ─────────────────────────────────────────────────────────────────────
async function main() {
  console.log('Fetching sample...')
  const nullCases = await fetchNullCases(15)
  const longCases = await fetchLongCases(10)
  const targetRandom = 200 - nullCases.length - longCases.length
  const random = await fetchRandom(targetRandom)

  // Dedupera på id
  const seen = new Set<string>()
  const sample: Row[] = []
  for (const r of [...nullCases, ...longCases, ...random]) {
    if (seen.has(r.id)) continue
    seen.add(r.id)
    sample.push(r)
    if (sample.length >= 200) break
  }

  console.log(`  Sample: ${sample.length}`)
  console.log(`    null-cases (episteme_educator_researcher IS NULL): ${nullCases.length}`)
  console.log(`    long-cases (total > TEXT_SLICE=${TEXT_SLICE}): ${longCases.length}`)
  console.log(`    random top-up: ${sample.length - nullCases.length - longCases.length}`)
  console.log('')

  let identical = 0
  let differ = 0
  let firstDiffRow: { row: Row, old: string, neu: string, at: number } | null = null

  for (const row of sample) {
    const oldStr = legacyInline(row)
    const newStr = buildEmbeddingText(row)
    if (oldStr === newStr) {
      identical++
    } else {
      differ++
      if (firstDiffRow === null) {
        firstDiffRow = { row, old: oldStr, neu: newStr, at: firstDiff(oldStr, newStr) }
      }
    }
  }

  console.log('─'.repeat(72))
  console.log(`Result: ${identical}/${sample.length} identical, ${differ} differ`)
  console.log('─'.repeat(72))

  if (differ > 0 && firstDiffRow) {
    const { row, old, neu, at } = firstDiffRow
    console.log(`\nFIRST DIFF at index ${at}:`)
    console.log(`  Article: ${row.id}`)
    console.log(`  old.length = ${old.length}, new.length = ${neu.length}`)
    console.log(`  old (context): ${showContext(old, at)}`)
    console.log(`  new (context): ${showContext(neu, at)}`)
    console.log(`  old.charCodeAt(${at}) = ${old.charCodeAt(at)} (${JSON.stringify(old[at])})`)
    console.log(`  new.charCodeAt(${at}) = ${neu.charCodeAt(at)} (${JSON.stringify(neu[at])})`)
    Deno.exit(1)
  }

  if (identical === sample.length && sample.length >= 200) {
    console.log('\n✓ BYTE-IDENTITY VERIFIED — refaktorn är säker att deploya.')
    Deno.exit(0)
  }

  if (sample.length < 200) {
    console.log(`\n⚠ Sample för litet (${sample.length}<200). Utred varför fetchRandom returnerade färre.`)
    Deno.exit(2)
  }
}

main().catch(e => { console.error(e); Deno.exit(1) })
