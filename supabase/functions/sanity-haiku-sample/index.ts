// Diagnos-fn: kör pipeline/index.ts:runSci-prompten mot Haiku 4.5 på ett
// stickprov från no-role + null-kw + DOI-populationen. Returnerar
// role_scores + keywords + study_type per artikel. Läs-only, INGEN
// DB-skrivning.
//
// Motivering: 2026-07-18 verifiering. Sanity #1 (stickprovs-abstracts)
// visade att no-role-populationen består av "unclassed but likely relevant"
// (candying, cheese safety, chickpea fermentation) — inte off-topic. Denna
// fn testar Haiku:s output på DENNA population innan induktiv backfill byggs.
//
// Behålls som permanent observability-verktyg (samma familj som
// stats_no_role_null_kw + sample_no_role_null_kw). Kostnad per anrop:
// ~800 tokens/artikel × N ≈ $0.005 per 8-stickprov. Ingen missbruksrisk
// (läs-only, kräver anon-JWT).
//
// USAGE:
//   curl -sS -X POST 'https://<ref>.supabase.co/functions/v1/sanity-haiku-sample?n=8' \
//     -H "apikey: $SB_ANON" -H "Authorization: Bearer $SB_ANON"
//
// SINGLE-SOURCE-VARNING (TILLFÄLLIG DUPLICATION):
// prompt + ROLES-listan är HÄR kopierade från pipeline/index.ts:22-49.
// Denna kopia är TILLFÄLLIG. Planen:
//   Steg 1: bygga denna diagnos-fn med kopia (för att köra sanity-testet
//           innan större refaktorering).
//   Steg 2: extrahera runSci + ROLES → _shared/haiku-sci.ts. EN källa.
//   Steg 3: pipeline/index.ts, denna fn OCH kommande backfill-fn
//           importerar ALLA från _shared/haiku-sci.ts. Ingen tre-kopia-drift.
//           Duplicerade konstanter tas bort HÄR då.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SB_URL = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SERVICE_ROLE_KEY') || ''
const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') || ''

const supabase = createClient(SB_URL, SB_SERVICE_KEY, {
  auth: { persistSession: false },
})

// EXAKT kopierat från pipeline/index.ts:22-28 (tas bort när haiku-sci.ts
// extraheras — se SINGLE-SOURCE-VARNING ovan).
const ROLES = [
  { role_key: 'sensory_pro',         role_label: 'Sommelier' },
  { role_key: 'culinary_pro',        role_label: 'Chef' },
  { role_key: 'gastronomy_culture',  role_label: 'Gastronomy' },
  { role_key: 'hospitality_mgmt',    role_label: 'F&B Manager' },
  { role_key: 'educator_researcher', role_label: 'Food Researcher & Educator' },
]

// EXAKT kopierat från pipeline/index.ts:39-62 (runSci). Tas bort när
// haiku-sci.ts extraheras.
async function runSci(article: { title?: string; abstract?: string; journal?: string }) {
  try {
    const roleList = ROLES.map(r => `"${r.role_key}":"${r.role_label}"`).join(',')
    const prompt = `Analyze for Gusto Science (culinary/hospitality platform).
Title: "${(article.title || '').slice(0, 200)}"
Abstract: "${(article.abstract || '').slice(0, 400)}"
Journal: "${article.journal || ''}"
Score relevance 0-10. BE STRICT: only high if professional can directly apply in daily work.
8-10: directly addresses core tasks. 5-7: clear indirect application. 1-4: marginal. 0: irrelevant.
Roles: {${roleList}}
Return ONLY JSON: {"role_scores":{"sensory_pro":0,"culinary_pro":0,"gastronomy_culture":0,"hospitality_mgmt":0,"educator_researcher":0},"keywords":["k1","k2"],"core_claim":"one precise factual finding","headline_en":"max 8 words no punctuation","study_type":"experimental|observational|review|meta-analysis|qualitative"}`

    const resp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': ANTHROPIC_KEY,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 500,
        messages: [{ role: 'user', content: prompt }],
      }),
    })
    if (!resp.ok) {
      const err = await resp.json().catch(() => ({}))
      return { error: `Haiku ${resp.status}`, detail: err }
    }
    const d = await resp.json()
    let t = (d.content?.[0]?.text || '{}').trim()
    t = t.replace(/^```json\s*/, '').replace(/^```\s*/, '').replace(/```[\s\S]*$/, '').trim()
    return JSON.parse(t)
  } catch (e: any) {
    return { error: 'runSci exception', detail: e.message }
  }
}

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
    const sci = await runSci({ title: full.title, abstract: full.abstract, journal: full.journal })
    if (sci?.error) {
      results.push({ id: a.id, title: a.title, error: sci.error, detail: sci.detail })
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
