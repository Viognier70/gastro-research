// backfill-affiliations
// ─────────────────────────────────────────────────────────────────────────────
// Per invocation: fetch up to BATCH_SIZE articles that still need affiliation
// data, resolve each DOI against OpenAlex, and persist the result via ONE
// SQL statement per row (SECURITY DEFINER RPC that sets attempted_at AND
// COALESCE-merges the data columns).
//
// Anders's four constraints (2026-07-08):
//   1) attempted_at and data in the SAME UPDATE. Handled by the RPC.
//   2) Break the batch on the first 429 — no point burning 97 more attempts
//      against the same rate-limit wall. Rows without attempted_at set will
//      resurface on the next cron tick.
//   3) mailto in the User-Agent → OpenAlex polite pool (~10 req/s vs ~1 in
//      the anonymous pool).
//   4) COALESCE on every data column — re-runs never overwrite existing
//      values. Also means partial data (e.g. institutions from Scopus but
//      no coords) survives when this fn later fills in the coords piece.
//
// Not attempted here (out of scope for fas 1):
//   - Scopus/PubMed fallback for OpenAlex misses. Decided after we measure
//     hit-rate from a full fas 1 run.
//   - Title-based lookup for DOI-less articles. Skipped by the target
//     predicate; separate fas.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SB_URL = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SERVICE_ROLE_KEY') || ''
const supabase = createClient(SB_URL, SB_SERVICE_KEY)

const OPENALEX_UA = 'GustoScience/1.0 (mailto:anders@crichton-fock.com)'
const BATCH_SIZE = 100
const CALL_DELAY_MS = 100

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Content-Type': 'application/json'
}

function extractDoi(url: string): string | null {
  const m = (url || '').match(/doi\.org\/(.+)$/i)
  return m ? m[1].trim() : null
}

type Outcome =
  | { kind: 'ok', data: {
      institutions:             string[],
      institution_openalex_ids: string[],  // parallel to institutions, same index → same inst
      institution_coords:       Array<{name:string,lat:number,lng:number,country:string}> | null,
      affiliations:             string[] | null,
      primary_institution:      string,
      country:                  string,
      countries:                string[]
    } }
  | { kind: 'missed' }                             // 200 with no institutions, or 404
  | { kind: 'retry_429' }                          // rate-limited — break the batch
  | { kind: 'retry_transient', reason: string }    // 5xx / network / timeout

async function fetchOpenAlex(doi: string): Promise<Outcome> {
  try {
    const r = await fetch(
      `https://api.openalex.org/works/doi:${encodeURIComponent(doi)}?select=authorships`,
      { headers: { 'User-Agent': OPENALEX_UA } }
    )
    if (r.status === 429) return { kind: 'retry_429' }
    if (r.status === 404) return { kind: 'missed' }
    if (r.status >= 500 || !r.ok) return { kind: 'retry_transient', reason: `HTTP ${r.status}` }

    const d = await r.json()
    const authorships = d.authorships || []
    const flatInsts = authorships.flatMap((a: any) => a.institutions || [])

    // institutions[] and institution_openalex_ids[] are built as parallel
    // arrays deduped by display_name — same index in both refers to the
    // same institution. The ID is what /institutions/{id} resolves against
    // (name is ambiguous — "Christ University", "Université de Maradi" vs
    // its Diffa campus, etc). Store the short form (strip openalex.org/
    // prefix); the API accepts both, short is cleaner in storage.
    const seen = new Set<string>()
    const institutions: string[] = []
    const institution_openalex_ids: string[] = []
    for (const inst of flatInsts) {
      const name = inst?.display_name
      if (!name || seen.has(name)) continue
      seen.add(name)
      institutions.push(name)
      const rawId = (inst?.id || '') as string
      institution_openalex_ids.push(
        rawId.replace(/^https?:\/\/openalex\.org\//, '')
      )
    }

    // Same-DOI 200 with no authorships = OpenAlex has the work but no
    // institutional signal. Attempted, missed — no fallback in fas 1.
    if (!institutions.length) return { kind: 'missed' }

    const institution_coords = flatInsts
      .filter((i: any) => i.geo?.latitude)
      .map((i: any) => ({
        name: i.display_name,
        lat: i.geo.latitude,
        lng: i.geo.longitude,
        country: i.country_code
      }))
      .filter((v: any, i: number, a: any[]) =>
        a.findIndex((x: any) => x.name === v.name) === i)

    const countries = [...new Set(
      flatInsts.map((i: any) => i.country_code).filter(Boolean)
    )] as string[]

    const affiliations = [...new Set(
      authorships.flatMap((a: any) => a.raw_affiliation_strings || []).filter(Boolean)
    )] as string[]

    return {
      kind: 'ok',
      data: {
        institutions,
        institution_openalex_ids,
        institution_coords: institution_coords.length ? institution_coords : null,
        affiliations:       affiliations.length       ? affiliations       : null,
        primary_institution: institutions[0],
        country:  countries[0] || '',
        countries
      }
    }
  } catch (e: any) {
    return { kind: 'retry_transient', reason: e?.message || 'network' }
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })

  const startedAt = Date.now()

  // Fas 1 target predicate. institutions IS NULL (not institution_coords —
  // Scopus rows now have institutions but never coords, and would otherwise
  // be picked forever). irrelevant = false excludes rows we won't display.
  // attempted_at IS NULL means we haven't tried OpenAlex yet, or the last
  // try was a transient (5xx/network) that didn't set attempted_at.
  const { data: articles, error: selectErr } = await supabase
    .from('articles')
    .select('id, url')
    .is('institutions', null)
    .is('affiliation_attempted_at', null)
    .eq('irrelevant', false)
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

  let updated = 0
  let missed = 0
  let transient_errors = 0
  let rpc_errors = 0
  let stopped_on_429 = false

  for (const article of articles) {
    const doi = extractDoi(article.url)
    if (!doi) {
      // ILIKE '%doi.org%' filter should prevent this — skip defensively.
      // Don't set attempted_at: nothing meaningful was attempted.
      continue
    }

    const outcome = await fetchOpenAlex(doi)

    if (outcome.kind === 'retry_429') {
      stopped_on_429 = true
      break
    }

    if (outcome.kind === 'retry_transient') {
      transient_errors++
      // Don't call the RPC — leave attempted_at NULL so the row is picked
      // up again next tick. Sleep before next OpenAlex call to be nice.
      await new Promise(r => setTimeout(r, CALL_DELAY_MS))
      continue
    }

    // outcome is 'ok' or 'missed'. Both call the same RPC — for 'missed'
    // all data args are null, so COALESCE is a no-op on data cols; only
    // affiliation_attempted_at is set.
    const data = outcome.kind === 'ok' ? outcome.data : null
    const { error: rpcErr } = await supabase.rpc('backfill_affiliations_update', {
      p_id:                       article.id,
      p_institutions:             data?.institutions             ?? null,
      p_institution_openalex_ids: data?.institution_openalex_ids ?? null,
      p_institution_coords:       data?.institution_coords       ?? null,
      p_affiliations:             data?.affiliations             ?? null,
      p_primary_institution:      data?.primary_institution      ?? null,
      p_country:                  data?.country                  ?? null,
      p_countries:                data?.countries                ?? null,
    })

    if (rpcErr) {
      // RPC failed → attempted_at didn't get set → row resurfaces next
      // tick. Treat as transient. Don't increment updated/missed since
      // the DB wasn't touched.
      console.log(`RPC error on ${article.id}:`, rpcErr.message)
      rpc_errors++
      await new Promise(r => setTimeout(r, CALL_DELAY_MS))
      continue
    }

    if (outcome.kind === 'ok') updated++
    else missed++

    await new Promise(r => setTimeout(r, CALL_DELAY_MS))
  }

  // Best-effort counter increment. If this fails we still return success
  // for the row-level work that landed — the progress table is
  // observability, not source of truth.
  if (updated || missed) {
    const { error: progErr } = await supabase.rpc(
      'backfill_affiliations_progress_add',
      { p_updated: updated, p_missed: missed }
    )
    if (progErr) console.log('progress_add error:', progErr.message)
  }

  return new Response(JSON.stringify({
    ok: true,
    batch_size: articles.length,
    updated,
    missed,
    transient_errors,
    rpc_errors,
    stopped_on_429,
    duration_ms: Date.now() - startedAt
  }), { headers: CORS })
})
