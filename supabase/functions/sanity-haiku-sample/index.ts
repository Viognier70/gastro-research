// Diagnos-fn: kör runSci (från _shared/haiku-sci.ts, samma modul som
// pipeline/index.ts och backfill-haiku-sci) mot Haiku 4.5 på ett stickprov
// från no-role + null-kw + DOI-populationen. Returnerar role_scores +
// keywords + study_type per artikel. Läs-only, INGEN DB-skrivning.
//
// Motivering: 2026-07-18 verifiering. Sanity #1 (stickprovs-abstracts)
// visade att no-role-populationen består av "unclassed but likely relevant"
// (candying, cheese safety, chickpea fermentation) — inte off-topic. Denna
// fn testar Haiku:s output på DENNA population innan induktiv backfill byggs.
//
// Efter refactor 2026-07-18: kör EXAKT samma runSci som pipeline (delad
// modul). Om denna fn ger rimlig sci-output → pipeline-refactorn är också
// bekräftad indirekt (samma kod-väg).
//
// Behålls som permanent observability-verktyg (samma familj som
// stats_no_role_null_kw + sample_no_role_null_kw). Kostnad per anrop:
// ~800 tokens/artikel × N ≈ $0.005 per 8-stickprov. Ingen missbruksrisk
// (läs-only, kräver anon-JWT).
//
// USAGE:
//   curl -sS -X POST 'https://<ref>.supabase.co/functions/v1/sanity-haiku-sample?n=8' \
//     -H "apikey: $SB_ANON" -H "Authorization: Bearer $SB_ANON"

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { runSci } from '../_shared/haiku-sci.ts'

const SB_URL = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') || ''

const supabase = createClient(SB_URL, SB_SERVICE_KEY, {
  auth: { persistSession: false },
})

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req) => {
  const url = new URL(req.url)
  const n = Math.min(20, Math.max(1, parseInt(url.searchParams.get('n') || '15', 10)))

  if (!ANTHROPIC_KEY) return json({ error: 'ANTHROPIC_API_KEY missing in fn env' }, 500)
  if (!SB_SERVICE_KEY) return json({ error: 'SERVICE_ROLE_KEY missing in fn env' }, 500)

  // Hämta stickprov via sample_no_role_null_kw(n)
  const { data: sample, error: rpcErr } = await supabase.rpc('sample_no_role_null_kw', { n })
  if (rpcErr) return json({ error: 'sample RPC failed', detail: rpcErr.message }, 500)
  if (!Array.isArray(sample) || sample.length === 0) {
    return json({ ok: true, results: [], note: 'population empty' })
  }

  const startedAt = Date.now()
  const results: any[] = []

  for (const a of sample) {
    // Hämta journal också (finns inte i sample-RPC:n; slå upp separat).
    // sample_no_role_null_kw returnerar {id, title, source, url, abstract_length, abstract_snippet}
    // — journal saknas, men Haiku-prompten behöver den. Hämta via id.
    const { data: full } = await supabase
      .from('articles')
      .select('title, abstract, journal')
      .eq('id', a.id)
      .single()
    if (!full) {
      results.push({ id: a.id, title: a.title, error: 'article fetch failed' })
      continue
    }
    const sci = await runSci(
      { title: full.title, abstract: full.abstract, journal: full.journal },
      ANTHROPIC_KEY
    )
    if (!sci) {
      results.push({ id: a.id, title: a.title, error: 'runSci returned null' })
      continue
    }

    // Beräkna vad DENNA scoring skulle betyda: max-score + skulle bli role-marked?
    const rs = sci.role_scores || {}
    const scores = [rs.sensory_pro, rs.culinary_pro, rs.gastronomy_culture, rs.hospitality_mgmt, rs.educator_researcher].map(v => Number(v) || 0)
    const max = Math.max(...scores)
    const wouldBecomeRoleMarked = max >= 5

    results.push({
      id: a.id,
      title: (a.title || '').slice(0, 80),
      source: a.source,
      abstract_length: a.abstract_length,
      role_scores: rs,
      max_score: max,
      would_become_role_marked: wouldBecomeRoleMarked,
      keywords: sci.keywords || [],
      study_type: sci.study_type || null,
      core_claim: (sci.core_claim || '').slice(0, 120),
      headline_en: sci.headline_en || null,
    })
  }

  // Sammanfattning
  const withKw = results.filter(r => Array.isArray(r.keywords) && r.keywords.length > 0)
  const roleMarked = results.filter(r => r.would_become_role_marked)
  const summary = {
    sampled: results.length,
    with_keywords: withKw.length,
    zero_keywords: results.length - withKw.length,
    would_become_role_marked: roleMarked.length,
    would_stay_no_role: results.length - roleMarked.length,
    avg_keyword_count: withKw.length
      ? +(withKw.reduce((s, r) => s + r.keywords.length, 0) / withKw.length).toFixed(1)
      : 0,
    elapsed_ms: Date.now() - startedAt,
  }

  return json({ ok: true, summary, results })
})
