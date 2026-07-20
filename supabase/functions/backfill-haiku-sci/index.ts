// Induktiv backfill av no-role-populationen via Haiku.
//
// Kör runSci (från _shared/haiku-sci.ts, samma modul som pipeline och
// sanity-fn) på artiklar med abstract > 50 chars, keywords IS NULL,
// alla relevance_sci_* < 5 eller NULL. Skriver via backfill_haiku_write-
// RPC atomiskt: articles-fält + processing_queue Metod B (status='skipped',
// sci_done=true, triad_done=false) för att blockera pipeline-TRIAD-kaskaden.
// TRIAD-svepet sker via triad-on-demand (klick), kvoterat.
//
// Sanity-check (2026-07-18, n=15) visade 15/15 skulle bli role-marked med
// avg 6.9 rena keywords per artikel. Populationen är "unclassed but likely
// gastro-relevant" — inte off-topic. Kostnad: ~$5-8 för 13k artiklar.
//
// USAGE (curl med anon-nyckel — bara för att nå fn; fn använder
// SERVICE_ROLE_KEY och ANTHROPIC_API_KEY från Supabase-env):
//
//   Dry-run (default: 20 artiklar, INGEN DB-skrivning):
//     curl -sS -X POST 'https://<ref>.supabase.co/functions/v1/backfill-haiku-sci' \
//       -H "apikey: $SB_ANON" -H "Authorization: Bearer $SB_ANON"
//
//   Dry-run med annan storlek:
//     curl ... '.../backfill-haiku-sci?dryrun=50'
//
//   LIVE (kräver server-side BACKFILL_HAIKU_LIVE_ENABLED=true):
//     supabase secrets set BACKFILL_HAIKU_LIVE_ENABLED=true --project-ref <ref>
//     curl ... '.../backfill-haiku-sci?live=true'
//     → Chunk-loop: repeatera tills summary.updated=0. Guard
//       'relevance_sci_sensory_pro IS NULL' gör redan-skrivna naturligt
//       exkluderade. ~13k / 30 per anrop = ~437 anrop.
//     supabase secrets unset BACKFILL_HAIKU_LIVE_ENABLED --project-ref <ref>
//
// SEPARAT GATE från BACKFILL_LIVE_ENABLED (OpenAlex-vägen) så en av dem
// kan öppnas medan den andra är stängd. Ingen kollision.
//
// TIMING: n=1 mätt 2.2s. Per-artikel i live: ~2.5s Haiku + 100ms rate +
// 200ms Metod B RPC = ~2.8s. Edge fn wall-time ~150s → DEFAULT_LIVE_LIMIT
// = 30 (30 × 2.8s = 84s säker marginal). Anders höjer via ?limit=N.
//
// PENDING-FÖRST-ORDERING (2026-07-18 alt 2 mot race):
// fetch_backfill_haiku_batch-RPC (migration 20260718130000) returnerar
// pending-artiklar (i queue) FÖRE absent (utanför queue), båda i
// fetched_at ASC-ordning (motsats till pipelinens DESC → picks olika
// artiklar → minimerar race där pipeline och backfill kör samma artikel).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { runSci } from '../_shared/haiku-sci.ts'

const SB_URL = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
const ANTHROPIC_KEY  = Deno.env.get('ANTHROPIC_API_KEY') || ''
const RATE_LIMIT_MS  = 100
const DEFAULT_DRYRUN_LIMIT = 20
// n=1 tog 2.2s (Haiku ~1.5-2s + parse + response). Per-artikel-total i
// live: 2.5s Haiku + 100ms rate_limit + 200ms Metod B RPC = ~2.8s.
// Edge fn wall-time ~150s → sätt DEFAULT_LIVE_LIMIT = 30 för säker
// marginal (30 × 2.8s = 84s < 150s). Anders kan höja via ?limit=N.
const DEFAULT_LIVE_LIMIT   = 30

const supabase = createClient(SB_URL, SB_SERVICE_KEY, {
  auth: { persistSession: false },
})

interface Article { id: string; title: string; abstract: string; journal: string; phase: string }

// Hämtar N artiklar via fetch_backfill_haiku_batch-RPC (SQL-sidan gör
// pending-först + fetched_at ASC + guard relevance_sci_sensory_pro IS NULL
// i EN transaktion). Motsats-ordering till pipelinens fetched_at DESC
// → minimerar race på samma artiklar. Se migration 20260718130000.
async function fetchPopulation(limit: number): Promise<Article[]> {
  const { data, error } = await supabase.rpc('fetch_backfill_haiku_batch', {
    p_limit: limit,
  })
  if (error) throw new Error(`fetchPopulation RPC failed: ${error.message}`)
  return (data || []) as Article[]
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req) => {
  if (!SB_SERVICE_KEY) return jsonResponse({ error: 'SERVICE_ROLE_KEY missing' }, 500)
  if (!ANTHROPIC_KEY)  return jsonResponse({ error: 'ANTHROPIC_API_KEY missing' }, 500)

  const url = new URL(req.url)
  const isLive = url.searchParams.get('live') === 'true'
  const dryrunRaw = url.searchParams.get('dryrun')
  const limitRaw  = url.searchParams.get('limit')
  const dryrunParam = dryrunRaw ? parseInt(dryrunRaw, 10) : NaN
  const limitParam  = limitRaw  ? parseInt(limitRaw, 10)  : NaN

  // Live-guard: separat env-flag från OpenAlex-backfillen.
  if (isLive && Deno.env.get('BACKFILL_HAIKU_LIVE_ENABLED') !== 'true') {
    return jsonResponse({
      error: 'live disabled',
      fix: 'supabase secrets set BACKFILL_HAIKU_LIVE_ENABLED=true --project-ref <ref>',
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
  } catch (e: any) {
    return jsonResponse({ ok: false, mode, error: 'population fetch', detail: String(e) }, 500)
  }

  const stats = {
    sampled: 0,
    phase_pending: 0,
    phase_absent: 0,
    haiku_ok: 0,
    haiku_fail: 0,
    updated: 0,
    skipped_already_written: 0,
    queue_updated: 0,          // = antal artiklar där Metod B UPDATE:ade en queue-rad
    would_become_role_marked: 0,
    zero_keywords: 0,
    write_errors: 0,
  }
  const counts: number[] = []
  const sample: any[] = []

  for (const a of articles) {
    stats.sampled++
    if (a.phase === 'pending') stats.phase_pending++
    else if (a.phase === 'absent') stats.phase_absent++
    const sci = await runSci(
      { title: a.title, abstract: a.abstract, journal: a.journal },
      ANTHROPIC_KEY
    )
    if (!sci) { stats.haiku_fail++; continue }
    stats.haiku_ok++

    const rs = sci.role_scores || {}
    const scores = [rs.sensory_pro, rs.culinary_pro, rs.gastronomy_culture, rs.hospitality_mgmt, rs.educator_researcher]
      .map(v => Number(v) || 0)
    const max = Math.max(...scores)
    const wouldRole = max >= 5
    if (wouldRole) stats.would_become_role_marked++

    const kws = sci.keywords || []
    counts.push(kws.length)
    if (kws.length === 0) stats.zero_keywords++

    if (sample.length < 20) {
      sample.push({
        id: a.id,
        title: a.title.slice(0, 70),
        phase: a.phase,   // 'pending' → Metod B UPDATE queue; 'absent' → no-op
        max_score: max,
        would_become_role_marked: wouldRole,
        role_scores: rs,
        keywords: kws,
        study_type: sci.study_type || null,
      })
    }

    if (isLive) {
      // Atomisk skrivning via RPC. Guard i RPC:n:
      // WHERE relevance_sci_sensory_pro IS NULL — idempotent.
      const { data, error } = await supabase.rpc('backfill_haiku_write', {
        p_article_id: a.id,
        p_role_scores: rs,
        p_keywords: kws,
        p_core_claim: sci.core_claim || null,
        p_headline_en: sci.headline_en || null,
        p_study_type: sci.study_type || null,
      })
      if (error) {
        stats.write_errors++
        console.log(`write error ${a.id.slice(0, 8)}:`, error.message)
      } else {
        const res = data as any
        if (res?.article_updated) {
          stats.updated++
          if (res.queue_updated) stats.queue_updated++
        } else if (res?.skipped) {
          stats.skipped_already_written++
        }
      }
    }

    await new Promise(r => setTimeout(r, RATE_LIMIT_MS))
  }

  const elapsed = Date.now() - startedAt
  const sorted = [...counts].sort((a, b) => a - b)
  const summary = {
    mode,
    limit,
    ...stats,
    elapsed_ms: elapsed,
    avg_keywords: counts.length ? +(counts.reduce((s, n) => s + n, 0) / counts.length).toFixed(1) : 0,
    median_keywords: sorted.length ? sorted[Math.floor(sorted.length / 2)] : 0,
    role_marked_pct: stats.sampled ? +(100 * stats.would_become_role_marked / stats.sampled).toFixed(1) : 0,
  }

  return jsonResponse({
    ok: true,
    summary,
    sample: isLive ? undefined : sample,
  })
})
