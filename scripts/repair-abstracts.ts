// scripts/repair-abstracts.ts
// ─────────────────────────────────────────────────────────────────────────
// ORDER 109 (Del 2, 2026-08-20) — abstract-reparation för trunkerade
// TRIAD-analyserade artiklar.
//
// FRISTÅENDE skript. Läser id-listan via SQL, hämtar färskt abstract
// från OpenAlex via url→doi, och anropar backfill_abstracts_overwrite()
// per rad (bara om nytt abstract är LÄNGRE än befintligt).
//
// DRY-RUN som default — skriver INGET utan --apply.
//
// KÖRNING (dry-run):
//   SUPABASE_SERVICE_ROLE_KEY=eyJ... \
//   OPENALEX_MAILTO=anders@crichton-fock.com \
//   deno run --allow-net --allow-env --allow-read --allow-write \
//     scripts/repair-abstracts.ts
//
// KÖRNING (apply):
//   SUPABASE_SERVICE_ROLE_KEY=eyJ... \
//   OPENALEX_MAILTO=anders@crichton-fock.com \
//   deno run --allow-net --allow-env --allow-read --allow-write \
//     scripts/repair-abstracts.ts --apply
//
// UTMATNING:
//   out/repair-abstracts.md — full logg per rad + summering
//   stdout                  — samma logg löpande
// ─────────────────────────────────────────────────────────────────────────

// ── Konfiguration ─────────────────────────────────────────────────────────
const SB_URL   = Deno.env.get('SUPABASE_URL') || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_KEY   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
const MAILTO   = Deno.env.get('OPENALEX_MAILTO') || ''
const APPLY    = Deno.args.includes('--apply')

const BATCH_SIZE       = 50
const BATCH_PAUSE_MS   = 2000
const PER_REQUEST_MS   = 150  // ~6.7 req/s mot OpenAlex, väl under polite pool-taket

const OUT_PATH = 'out/repair-abstracts.md'

// ── Envcheck ──────────────────────────────────────────────────────────────
if (!SB_KEY) {
  console.error('Missing env: SUPABASE_SERVICE_ROLE_KEY krävs.')
  Deno.exit(2)
}
if (!MAILTO) {
  console.warn('[warn] OPENALEX_MAILTO ej satt — OpenAlex polite pool ger snabbare svar med mailto.')
}

// ── Typer ─────────────────────────────────────────────────────────────────
type Target = {
  id:          string
  url:         string | null
  abstract:    string
  abstract_len:number
}

type Outcome =
  | 'no-doi'                 // url matchar inte doi.org-mönstret
  | 'openalex-404'           // DOI inte i OpenAlex
  | 'openalex-error'         // annat HTTP-fel eller nätverksfel
  | 'openalex-no-abstract'   // DOI hittad, inget abstract_inverted_index
  | 'not-longer'             // nytt abstract inte längre än befintligt
  | 'guard-too-short'        // < 100 tecken → RPC:n skulle no-op:a
  | 'wrote'                  // faktiskt skrivet (--apply)
  | 'would-write'            // dry-run, skulle ha skrivit

type Row = {
  id:      string
  old_len: number
  new_len: number
  gained:  number
  outcome: Outcome
  detail?: string
}

// ── DOI ur url ────────────────────────────────────────────────────────────
function doiFromUrl(url: string | null | undefined): string {
  if (!url) return ''
  const m = /^https?:\/\/(?:dx\.)?doi\.org\/(.+)$/i.exec(url.trim())
  return m ? m[1] : ''
}

// ── OpenAlex abstract-rekonstruktion ──────────────────────────────────────
// OpenAlex returnerar abstract_inverted_index (map word → [positions]) för
// juridisk clean-room-anledning. Positionerna är 0-indexerade i den
// ursprungliga texten; rekonstruerar genom att placera varje ord på sin
// position i en array och sen joina.
function reconstructAbstract(idx: Record<string, number[]> | null | undefined): string {
  if (!idx || typeof idx !== 'object') return ''
  const words: string[] = []
  for (const [word, positions] of Object.entries(idx)) {
    if (!Array.isArray(positions)) continue
    for (const pos of positions) {
      if (typeof pos === 'number' && pos >= 0) words[pos] = word
    }
  }
  return words.filter(Boolean).join(' ').trim()
}

// ── HTTP-hjälpare ─────────────────────────────────────────────────────────
async function sbGet(path: string): Promise<any> {
  const r = await fetch(`${SB_URL}${path}`, {
    headers: {
      'apikey':        SB_KEY,
      'Authorization': `Bearer ${SB_KEY}`,
    }
  })
  if (!r.ok) {
    const t = await r.text().catch(() => '<unread>')
    throw new Error(`Supabase ${r.status}: ${t.slice(0,200)}`)
  }
  return await r.json()
}

async function fetchOpenAlex(doi: string): Promise<{status: number, abstract: string}> {
  const mailtoParam = MAILTO ? `?mailto=${encodeURIComponent(MAILTO)}` : ''
  const url = `https://api.openalex.org/works/doi:${encodeURIComponent(doi)}${mailtoParam}`
  const r = await fetch(url, {
    headers: {'User-Agent': 'GustoScience-repair-abstracts/1.0'}
  })
  if (r.status === 404) return { status: 404, abstract: '' }
  if (!r.ok) return { status: r.status, abstract: '' }
  const d = await r.json().catch(() => ({}))
  return { status: 200, abstract: reconstructAbstract(d?.abstract_inverted_index) }
}

async function rpcOverwrite(id: string, abstract: string): Promise<void> {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/backfill_abstracts_overwrite`, {
    method: 'POST',
    headers: {
      'apikey':        SB_KEY,
      'Authorization': `Bearer ${SB_KEY}`,
      'Content-Type':  'application/json',
    },
    body: JSON.stringify({ p_id: id, p_abstract: abstract }),
  })
  if (!r.ok) {
    const t = await r.text().catch(() => '<unread>')
    throw new Error(`overwrite ${r.status}: ${t.slice(0,200)}`)
  }
}

// ── Trunkerings-check (rtrim + sista tecken) ──────────────────────────────
// Utvärderas klientside för att vara oberoende av eventuell trailing
// whitespace i databasen. Rader som slutar på . ! ? ) räknas som HELA.
function isTruncated(abstract: string): boolean {
  const trimmed = abstract.replace(/\s+$/, '')
  if (!trimmed) return false  // tomt abstract är inte "trunkerat" i vår mening
  return !/[.!?)]$/.test(trimmed)
}

// ── Fetcha kandidater ─────────────────────────────────────────────────────
// Filter: abstract IS NOT NULL AND (episteme_<n> IS NOT NULL) AND
// LIKE-chain för att grovsålla trunkerade. Klientside re-verifierar med
// isTruncated(). Pagination för att undvika PostgREST-tak (default 1000).
async function fetchTargets(): Promise<Target[]> {
  const pageSize = 1000
  let offset = 0
  const all: Target[] = []
  while (true) {
    const params = new URLSearchParams()
    params.append('select', 'id,url,abstract')
    params.append('abstract', 'not.is.null')
    params.append('or', '(episteme_sensory_pro.not.is.null,episteme_culinary_pro.not.is.null,episteme_gastronomy_culture.not.is.null,episteme_hospitality_mgmt.not.is.null,episteme_educator_researcher.not.is.null)')
    // Grovsåll — matchar de flesta trunkerade (falska positiva från
    // trailing whitespace filtreras klientside):
    params.append('abstract', 'not.ilike.*.')
    params.append('abstract', 'not.ilike.*!')
    params.append('abstract', 'not.ilike.*?')
    params.append('abstract', 'not.ilike.*)')
    params.append('order', 'id')
    params.append('limit', String(pageSize))
    params.append('offset', String(offset))

    const rows: any[] = await sbGet(`/rest/v1/articles?${params.toString()}`)
    if (!Array.isArray(rows) || rows.length === 0) break

    for (const r of rows) {
      if (!r.abstract || !isTruncated(r.abstract)) continue
      all.push({
        id:           r.id,
        url:          r.url,
        abstract:     r.abstract,
        abstract_len: r.abstract.length,
      })
    }
    console.log(`[fetch] offset=${offset}  page=${rows.length}  passed-verify=${all.length} totalt`)
    if (rows.length < pageSize) break
    offset += pageSize
  }
  return all
}

// ── Huvudloop ─────────────────────────────────────────────────────────────
async function main() {
  const startedAt = new Date().toISOString()
  console.log(`[start] mode=${APPLY ? 'APPLY' : 'DRY-RUN'}  at=${startedAt}`)

  const targets = await fetchTargets()
  console.log(`[fetch] ${targets.length} trunkerade TRIAD-artiklar identifierade`)

  const rows: Row[] = []
  const counters: Record<Outcome, number> = {
    'no-doi': 0, 'openalex-404': 0, 'openalex-error': 0,
    'openalex-no-abstract': 0, 'not-longer': 0, 'guard-too-short': 0,
    'wrote': 0, 'would-write': 0,
  }
  let gainedTotal = 0
  let gainedCount = 0

  for (let i = 0; i < targets.length; i += BATCH_SIZE) {
    const batch = targets.slice(i, i + BATCH_SIZE)
    const batchNo = Math.floor(i / BATCH_SIZE) + 1
    const totalBatches = Math.ceil(targets.length / BATCH_SIZE)
    console.log(`\n[batch ${batchNo}/${totalBatches}]  ${batch.length} rader`)

    for (const t of batch) {
      const doi = doiFromUrl(t.url)
      if (!doi) {
        rows.push({ id: t.id, old_len: t.abstract_len, new_len: 0, gained: 0, outcome: 'no-doi', detail: t.url || '' })
        counters['no-doi']++
        console.log(`  ${t.id}  ${t.abstract_len} → -    no-doi  (url=${(t.url||'').slice(0,60)})`)
        continue
      }

      let oa: { status: number, abstract: string }
      try {
        oa = await fetchOpenAlex(doi)
      } catch (e) {
        const detail = e instanceof Error ? e.message : String(e)
        rows.push({ id: t.id, old_len: t.abstract_len, new_len: 0, gained: 0, outcome: 'openalex-error', detail })
        counters['openalex-error']++
        console.log(`  ${t.id}  ${t.abstract_len} → -    openalex-error  ${detail.slice(0,80)}`)
        await new Promise(r => setTimeout(r, PER_REQUEST_MS))
        continue
      }

      if (oa.status === 404) {
        rows.push({ id: t.id, old_len: t.abstract_len, new_len: 0, gained: 0, outcome: 'openalex-404' })
        counters['openalex-404']++
        console.log(`  ${t.id}  ${t.abstract_len} → -    openalex-404`)
      } else if (oa.status !== 200) {
        rows.push({ id: t.id, old_len: t.abstract_len, new_len: 0, gained: 0, outcome: 'openalex-error', detail: `HTTP ${oa.status}` })
        counters['openalex-error']++
        console.log(`  ${t.id}  ${t.abstract_len} → -    openalex-error  HTTP ${oa.status}`)
      } else if (!oa.abstract) {
        rows.push({ id: t.id, old_len: t.abstract_len, new_len: 0, gained: 0, outcome: 'openalex-no-abstract' })
        counters['openalex-no-abstract']++
        console.log(`  ${t.id}  ${t.abstract_len} → 0    openalex-no-abstract`)
      } else {
        const newLen = oa.abstract.length
        const gained = newLen - t.abstract_len
        if (newLen < 100) {
          rows.push({ id: t.id, old_len: t.abstract_len, new_len: newLen, gained, outcome: 'guard-too-short' })
          counters['guard-too-short']++
          console.log(`  ${t.id}  ${t.abstract_len} → ${newLen}  guard-too-short`)
        } else if (gained <= 0) {
          rows.push({ id: t.id, old_len: t.abstract_len, new_len: newLen, gained, outcome: 'not-longer' })
          counters['not-longer']++
          console.log(`  ${t.id}  ${t.abstract_len} → ${newLen}  not-longer  (gained=${gained})`)
        } else {
          if (APPLY) {
            try {
              await rpcOverwrite(t.id, oa.abstract)
              rows.push({ id: t.id, old_len: t.abstract_len, new_len: newLen, gained, outcome: 'wrote' })
              counters['wrote']++
              gainedTotal += gained
              gainedCount++
              console.log(`  ${t.id}  ${t.abstract_len} → ${newLen}  WROTE  (+${gained})`)
            } catch (e) {
              const detail = e instanceof Error ? e.message : String(e)
              rows.push({ id: t.id, old_len: t.abstract_len, new_len: newLen, gained, outcome: 'openalex-error', detail: 'rpc: '+detail })
              counters['openalex-error']++
              console.log(`  ${t.id}  ${t.abstract_len} → ${newLen}  RPC-ERROR  ${detail.slice(0,80)}`)
            }
          } else {
            rows.push({ id: t.id, old_len: t.abstract_len, new_len: newLen, gained, outcome: 'would-write' })
            counters['would-write']++
            gainedTotal += gained
            gainedCount++
            console.log(`  ${t.id}  ${t.abstract_len} → ${newLen}  would-write  (+${gained})`)
          }
        }
      }

      await new Promise(r => setTimeout(r, PER_REQUEST_MS))
    }

    if (i + BATCH_SIZE < targets.length) {
      console.log(`[batch ${batchNo}/${totalBatches}] paus ${BATCH_PAUSE_MS}ms`)
      await new Promise(r => setTimeout(r, BATCH_PAUSE_MS))
    }
  }

  // ── Markdown-rapport ────────────────────────────────────────────────────
  const finishedAt = new Date().toISOString()
  const lines: string[] = []
  lines.push(`# Abstract Repair — ${finishedAt.slice(0,10)}`)
  lines.push('')
  lines.push(`- Mode: **${APPLY ? 'APPLY (skrev)' : 'DRY-RUN (skrev inte)'}**`)
  lines.push(`- Startade: ${startedAt}`)
  lines.push(`- Klar: ${finishedAt}`)
  lines.push(`- Targets (trunkerade TRIAD-artiklar): **${targets.length}**`)
  lines.push('')
  lines.push('## Utfall per rad')
  lines.push('')
  lines.push('| Outcome | Räkning |')
  lines.push('|---|---:|')
  const orderedOutcomes: Outcome[] = APPLY
    ? ['wrote','not-longer','guard-too-short','openalex-no-abstract','openalex-404','no-doi','openalex-error']
    : ['would-write','not-longer','guard-too-short','openalex-no-abstract','openalex-404','no-doi','openalex-error']
  for (const k of orderedOutcomes) {
    lines.push(`| \`${k}\` | ${counters[k]} |`)
  }
  lines.push('')
  lines.push('## Kärnrapport')
  lines.push('')
  const wroteKey: Outcome = APPLY ? 'wrote' : 'would-write'
  const avgGain = gainedCount > 0 ? Math.round(gainedTotal / gainedCount) : 0
  lines.push(`- Artiklar som ${APPLY ? 'fick' : 'skulle fått'} längre abstract: **${gainedCount}**`)
  lines.push(`- Total tecken-vinst: **${gainedTotal.toLocaleString('sv-SE')}**`)
  lines.push(`- Snitt-vinst per artikel: **+${avgGain} tecken**`)
  lines.push('')
  lines.push(`_(motsvarar counters['${wroteKey}'] = ${counters[wroteKey]})_`)
  lines.push('')
  lines.push('## Per rad (alla utfall)')
  lines.push('')
  lines.push('| id | old_len | new_len | gained | outcome | detail |')
  lines.push('|---|---:|---:|---:|---|---|')
  for (const r of rows) {
    const detail = (r.detail || '').replace(/\|/g,'\\|').slice(0,80)
    lines.push(`| \`${r.id}\` | ${r.old_len} | ${r.new_len || '-'} | ${r.gained > 0 ? '+'+r.gained : (r.gained || '-')} | \`${r.outcome}\` | ${detail} |`)
  }
  lines.push('')

  await Deno.mkdir('out', { recursive: true }).catch(() => {})
  await Deno.writeTextFile(OUT_PATH, lines.join('\n') + '\n')
  console.log(`\n[done] skrev ${OUT_PATH}`)
  console.log(`[done] mode=${APPLY ? 'APPLY' : 'DRY-RUN'}  targets=${targets.length}  ${wroteKey}=${counters[wroteKey]}  gained-total=${gainedTotal}`)
}

main().catch(e => {
  console.error('[FATAL]', e)
  Deno.exit(1)
})
