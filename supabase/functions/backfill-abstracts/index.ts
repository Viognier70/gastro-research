// backfill-abstracts (rewrite 2026-07-09)
// ─────────────────────────────────────────────────────────────────────────────
// Per invocation: fetch up to BATCH_SIZE articles that still need an abstract,
// resolve each DOI against OpenAlex (abstract_inverted_index), fall back to
// Crossref, and persist the result via ONE SQL statement per row (the
// backfill_abstracts_update RPC — attempted_at set unconditionally, abstract
// merged via COALESCE, both in one atomic UPDATE).
//
// Design points from arbetsordern (Anders, 2026-07-09):
//
//   - No '[unavailable]' sentinel. The old fn hit Crossref once, wrote the
//     sentinel on failure, and locked ~42k rows out of relevance-check
//     forever because that value didn't match `abstract IS NULL` on the
//     next attempt. This fn writes NULL for "attempted, no abstract found"
//     — abstract_attempted_at is the marker instead. To retry a row, null
//     out its attempted_at.
//
//   - attempted_at is set ONLY when a source responded meaningfully:
//     OpenAlex 200 (with or without abstract) or 404, and — if OpenAlex
//     missed — Crossref 200 or 404. Any 429 breaks the batch. Any 5xx /
//     network / timeout leaves attempted_at NULL so the row resurfaces
//     next tick.
//
//   - OpenAlex first because its polite-pool coverage for our corpus is
//     substantially better than Crossref, and abstract_inverted_index
//     usually reconstructs to > 50 chars when a work has an abstract at
//     all. Crossref is the pragmatic fallback: it holds abstracts for
//     some works OpenAlex doesn't have.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SB_URL = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
const supabase = createClient(SB_URL, SB_SERVICE_KEY)

const OPENALEX_UA = 'GustoScience/1.0 (mailto:anders@crichton-fock.com)'
const CROSSREF_UA = 'GustoScience/1.0 (mailto:anders@crichton-fock.com)'
const BATCH_SIZE = 200
const CALL_DELAY_MS = 100
const MIN_ABSTRACT_LEN = 50

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Content-Type': 'application/json'
}

function extractDoi(url: string): string | null {
  const m = (url || '').match(/doi\.org\/(.+)$/i)
  return m ? m[1].trim() : null
}

// OpenAlex serves abstracts as a positional inverted index — reconstruct
// linearly. Same helper as in daily-fetch/fetchOpenAlexPage; duplicated
// (rather than shared) so this edge fn stays self-contained.
function reconstructAbstract(
  inv: Record<string, number[]> | null | undefined
): string {
  if (!inv || typeof inv !== 'object') return ''
  const positions: [number, string][] = []
  for (const [word, indices] of Object.entries(inv)) {
    if (!Array.isArray(indices)) continue
    for (const i of indices) if (typeof i === 'number') positions.push([i, word])
  }
  if (!positions.length) return ''
  positions.sort((a, b) => a[0] - b[0])
  return positions.map(([, w]) => w).join(' ')
}

type Outcome =
  | { kind: 'ok', abstract: string }             // usable text found
  | { kind: 'missed' }                            // 200 w/o abstract, or 404
  | { kind: 'retry_429' }                         // rate-limited
  | { kind: 'retry_transient', reason: string }   // 5xx / network / timeout

async function fetchOpenAlex(doi: string): Promise<Outcome> {
  try {
    const r = await fetch(
      `https://api.openalex.org/works/doi:${encodeURIComponent(doi)}?select=abstract_inverted_index`,
      { headers: { 'User-Agent': OPENALEX_UA } }
    )
    if (r.status === 429) return { kind: 'retry_429' }
    if (r.status === 404) return { kind: 'missed' }
    if (r.status >= 500 || !r.ok) return { kind: 'retry_transient', reason: `HTTP ${r.status}` }
    const d = await r.json()
    const abs = reconstructAbstract(d.abstract_inverted_index)
    if (abs.length >= MIN_ABSTRACT_LEN) return { kind: 'ok', abstract: abs }
    return { kind: 'missed' }
  } catch (e: any) {
    return { kind: 'retry_transient', reason: e?.message || 'network' }
  }
}

async function fetchCrossref(doi: string): Promise<Outcome> {
  try {
    const r = await fetch(
      `https://api.crossref.org/works/${encodeURIComponent(doi)}`,
      { headers: { 'User-Agent': CROSSREF_UA } }
    )
    if (r.status === 429) return { kind: 'retry_429' }
    if (r.status === 404) return { kind: 'missed' }
    if (r.status >= 500 || !r.ok) return { kind: 'retry_transient', reason: `HTTP ${r.status}` }
    const d = await r.json()
    // Crossref stores abstract as HTML with JATS tags — strip them.
    const raw = d?.message?.abstract || ''
    const abs = raw.replace(/<[^>]+>/g, '').trim()
    if (abs.length >= MIN_ABSTRACT_LEN) return { kind: 'ok', abstract: abs }
    return { kind: 'missed' }
  } catch (e: any) {
    return { kind: 'retry_transient', reason: e?.message || 'network' }
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  const startedAt = Date.now()

  // Target predicate: rows where the abstract slot is empty and no source
  // has been asked yet. url ILIKE '%doi.org%' is the DOI-required filter —
  // rows without a DOI are skipped (fas 2 territory if we want them).
  const { data: articles, error: selectErr } = await supabase
    .from('articles')
    .select('id, url')
    .is('abstract', null)
    .is('abstract_attempted_at', null)
    .ilike('url', '%doi.org%')
    .order('id')
    .limit(BATCH_SIZE)

  if (selectErr) {
    return new Response(
      JSON.stringify({ ok: false, error: selectErr.message }),
      { status: 500, headers: CORS }
    )
  }
  if (!articles?.length) {
    return new Response(
      JSON.stringify({ ok: true, batch_size: 0, message: 'nothing pending' }),
      { headers: CORS }
    )
  }

  let filled = 0
  let missed = 0
  let transient_errors = 0
  let rpc_errors = 0
  let stopped_on_429 = false
  let openalex_hits = 0
  let crossref_hits = 0

  for (const article of articles) {
    const doi = extractDoi(article.url)
    if (!doi) {
      // Defensive — the ILIKE filter should already exclude this.
      continue
    }

    // Try OpenAlex first.
    const oa = await fetchOpenAlex(doi)
    if (oa.kind === 'retry_429') { stopped_on_429 = true; break }
    if (oa.kind === 'retry_transient') {
      transient_errors++
      await new Promise(r => setTimeout(r, CALL_DELAY_MS))
      continue
    }

    let abstract: string | null = null
    if (oa.kind === 'ok') {
      abstract = oa.abstract
      openalex_hits++
    } else {
      // OpenAlex missed → try Crossref.
      const cr = await fetchCrossref(doi)
      if (cr.kind === 'retry_429') { stopped_on_429 = true; break }
      if (cr.kind === 'retry_transient') {
        transient_errors++
        await new Promise(r => setTimeout(r, CALL_DELAY_MS))
        continue
      }
      if (cr.kind === 'ok') {
        abstract = cr.abstract
        crossref_hits++
      }
      // else: both sources missed — abstract stays null, attempted_at set below
    }

    // Single-statement UPDATE via RPC: attempted_at + COALESCE(abstract).
    // NULL arg is a no-op on the abstract column but always sets attempted_at.
    const { error: rpcErr } = await supabase.rpc('backfill_abstracts_update', {
      p_id: article.id,
      p_abstract: abstract,
    })

    if (rpcErr) {
      // RPC failed → attempted_at didn't get written → row resurfaces
      // next tick. Log and continue.
      console.log(`RPC error on ${article.id}:`, rpcErr.message)
      rpc_errors++
      await new Promise(r => setTimeout(r, CALL_DELAY_MS))
      continue
    }

    if (abstract) filled++
    else missed++

    await new Promise(r => setTimeout(r, CALL_DELAY_MS))
  }

  return new Response(JSON.stringify({
    ok: true,
    batch_size: articles.length,
    filled,
    missed,
    openalex_hits,
    crossref_hits,
    transient_errors,
    rpc_errors,
    stopped_on_429,
    duration_ms: Date.now() - startedAt
  }), { headers: CORS })
})
