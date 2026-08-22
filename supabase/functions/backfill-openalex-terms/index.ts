// Backfill av keywords för no-role-artiklar. Kör INUTI Supabase — läser
// SERVICE_ROLE_KEY från fn:ens env (samma pattern som daily-fetch/pipeline),
// ingen manuell nyckelhantering.
//
// Använder samma _shared/openalex-terms.ts som daily-fetch — validerad modul
// (post-deploy-stickprov 2026-07-17: 15/15 sci-processade, merge fungerar,
// fallback triggade 0/15 där; väntas oftare på 13k-svansen som är äldre).
//
// USAGE (curl med anon-nyckel — bara för att anropa fn; fn använder sin
// egen SERVICE_ROLE_KEY internt):
//
//   Dry-run 100 (default, INGEN DB-skrivning, returnerar summary + 20 sample):
//     curl -sS -X POST 'https://<ref>.supabase.co/functions/v1/backfill-openalex-terms' \
//       -H "apikey: $SB_ANON" -H "Authorization: Bearer $SB_ANON"
//
//   Dry-run med annan limit:
//     curl ... '.../backfill-openalex-terms?dryrun=50'
//
//   LIVE (kräver server-side env-toggle av säkerhetsskäl):
//     1. supabase secrets set BACKFILL_LIVE_ENABLED=true --project-ref <ref>
//     2. curl ... '.../backfill-openalex-terms?live=true'
//     3. Repetera curlen tills summary.updated=0 (guard "keywords IS NULL"
//        gör att redan-skrivna naturligt exkluderas — ~27 anrop för 13k).
//     4. supabase secrets unset BACKFILL_LIVE_ENABLED --project-ref <ref>
//
//   Chunkning: default limit i live-läget = DEFAULT_LIVE_LIMIT (500)
//   för att fit i ~150s edge-timeout. Override med ?limit=N.
//
// GUARD: skriver ENDAST till keywords IS NULL. Idempotent — samtidiga
// skrivare respekteras.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { openAlexToKeywords, MIN_TERMS } from '../_shared/openalex-terms.ts'

const SB_URL = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
const MAILTO = 'anders@crichton-fock.com'
const BATCH_SIZE = 50
const RATE_LIMIT_MS = 150
const DEFAULT_DRYRUN_LIMIT = 100
const DEFAULT_LIVE_LIMIT = 500

const supabase = createClient(SB_URL, SB_SERVICE_KEY, {
  auth: { persistSession: false },
})

interface Article { id: string; url: string; title: string }

// Population-fetch använder raw PostgREST-URL: PostgREST or-inuti-and via
// query-syntax är otymplig via supabase-js builder-kedjan (multipla .or()
// har historiskt driftat i bibliotekets olika versioner).
async function fetchPopulation(limit: number): Promise<Article[]> {
  const filters = [
    'select=id,url,title',
    'irrelevant=eq.false',
    'keywords=is.null',
    'url=ilike.*doi.org/*',
    'abstract=not.is.null',
    'and=(or(relevance_sci_sensory_pro.lt.5,relevance_sci_sensory_pro.is.null),' +
      'or(relevance_sci_culinary_pro.lt.5,relevance_sci_culinary_pro.is.null),' +
      'or(relevance_sci_gastronomy_culture.lt.5,relevance_sci_gastronomy_culture.is.null),' +
      'or(relevance_sci_hospitality_mgmt.lt.5,relevance_sci_hospitality_mgmt.is.null),' +
      'or(relevance_sci_educator_researcher.lt.5,relevance_sci_educator_researcher.is.null))',
    'order=fetched_at.desc',
    `limit=${limit}`,
  ]
  const url = `${SB_URL}/rest/v1/articles?${filters.join('&')}`
  const r = await fetch(url, {
    headers: {
      'apikey': SB_SERVICE_KEY,
      'Authorization': `Bearer ${SB_SERVICE_KEY}`,
    },
  })
  if (!r.ok) throw new Error(`population fetch ${r.status}: ${await r.text()}`)
  return await r.json()
}

async function fetchOpenAlexBatch(dois: string[]): Promise<Map<string, any>> {
  const filter = 'doi:' + dois.join('|')
  const url = `https://api.openalex.org/works?filter=${encodeURIComponent(filter)}&per-page=${BATCH_SIZE}&mailto=${MAILTO}`
  const r = await fetch(url, { headers: { 'User-Agent': 'gusto-science-backfill-fn/1.0' } })
  if (!r.ok) return new Map()
  const d = await r.json()
  const out = new Map<string, any>()
  for (const w of (d.results || [])) {
    const doi = (w.doi || '').replace(/^https?:\/\/doi\.org\//i, '').toLowerCase()
    if (doi) out.set(doi, w)
  }
  return out
}

function urlToDoi(u: string): string {
  return (u || '').replace(/^https?:\/\/doi\.org\//i, '').trim()
}

// Detekterar om concepts-fallback triggade genom att anropa MODULENS funktion
// med concepts=[] — då kan fallback inte trigga, och resultatet är exakt
// primär. Ingen parallell implementation → drift-fri (lärdom 4).
function primaryTermCountViaModule(work: any): number {
  if (!work) return 0
  return openAlexToKeywords({ ...work, concepts: [] }).length
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req) => {
  const url = new URL(req.url)
  const isLive = url.searchParams.get('live') === 'true'
  const dryrunParamRaw = url.searchParams.get('dryrun')
  const limitParamRaw = url.searchParams.get('limit')
  const dryrunParam = dryrunParamRaw ? parseInt(dryrunParamRaw, 10) : NaN
  const limitParam = limitParamRaw ? parseInt(limitParamRaw, 10) : NaN

  // Live-guard: kräver server-side env-toggle (skyddar mot att någon som
  // har anon-nyckeln kan trigga 13k-skrivning oavsiktligt).
  if (isLive && Deno.env.get('BACKFILL_LIVE_ENABLED') !== 'true') {
    return jsonResponse({
      error: 'live disabled',
      fix: 'supabase secrets set BACKFILL_LIVE_ENABLED=true --project-ref <ref>, sen re-invoke',
    }, 403)
  }

  const limit = Number.isFinite(limitParam)
    ? limitParam
    : (isLive
      ? DEFAULT_LIVE_LIMIT
      : (Number.isFinite(dryrunParam) ? dryrunParam : DEFAULT_DRYRUN_LIMIT))

  const mode = isLive ? 'live' : 'dryrun'
  const startedAt = Date.now()

  let articles: Article[]
  try {
    articles = await fetchPopulation(limit)
  } catch (e) {
    return jsonResponse({ ok: false, mode, error: 'population fetch', detail: String(e) }, 500)
  }

  const stats = {
    found: 0, missing: 0,
    with_keywords: 0, zero_keywords: 0,
    fallback_triggered: 0,
    updated: 0, failed: 0,
  }
  const counts: number[] = []
  const sample: Array<{
    id: string; title: string; n: number;
    fallback: boolean; fallback_added: number; keywords: string[];
  }> = []

  for (let i = 0; i < articles.length; i += BATCH_SIZE) {
    const chunk = articles.slice(i, i + BATCH_SIZE)
    const dois = chunk.map(a => urlToDoi(a.url)).filter(Boolean)
    const doiToArticle = new Map(chunk.map(a => [urlToDoi(a.url).toLowerCase(), a]))
    const works = await fetchOpenAlexBatch(dois)

    for (const [doi, work] of works) {
      stats.found++
      const article = doiToArticle.get(doi)
      if (!article) continue

      const primaryN = primaryTermCountViaModule(work)
      const keywords = openAlexToKeywords(work)
      const fbTriggered = keywords.length > primaryN
      const fbAdded = keywords.length - primaryN

      counts.push(keywords.length)
      if (keywords.length > 0) stats.with_keywords++
      else stats.zero_keywords++
      if (fbTriggered) stats.fallback_triggered++

      if (sample.length < 20) {
        sample.push({
          id: article.id,
          title: article.title,
          n: keywords.length,
          fallback: fbTriggered,
          fallback_added: fbAdded,
          keywords,
        })
      }

      if (isLive && keywords.length > 0) {
        const { error } = await supabase
          .from('articles')
          .update({ keywords })
          .eq('id', article.id)
          .is('keywords', null)
        if (error) stats.failed++
        else stats.updated++
      }
    }

    for (const d of dois) {
      if (!works.has(d.toLowerCase())) stats.missing++
    }

    await new Promise(r => setTimeout(r, RATE_LIMIT_MS))
  }

  const elapsed = Date.now() - startedAt
  const sorted = [...counts].sort((a, b) => a - b)
  const summary = {
    mode,
    limit,
    min_terms_config: MIN_TERMS,
    population_returned: articles.length,
    ...stats,
    elapsed_ms: elapsed,
    avg: counts.length ? +(counts.reduce((a, b) => a + b, 0) / counts.length).toFixed(1) : 0,
    median: sorted.length ? sorted[Math.floor(sorted.length / 2)] : 0,
    min: sorted[0] ?? null,
    max: sorted.at(-1) ?? null,
    fallback_pct: stats.found ? +(100 * stats.fallback_triggered / stats.found).toFixed(1) : 0,
    zero_pct: stats.found ? +(100 * stats.zero_keywords / stats.found).toFixed(1) : 0,
  }

  return jsonResponse({
    ok: true,
    summary,
    sample: isLive ? undefined : sample,
  })
})
