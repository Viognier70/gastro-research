// triad-background
// ─────────────────────────────────────────────────────────────────────────────
// Bakgrunds-TRIAD för spotlight-artiklar. Var 30:e min via cron. Hämtar
// top-N mest relevanta artiklar som saknar TRIAD (via RPC
// triad_background_candidates), kör Sonnet 4.6 runTriad, skriver till DB.
//
// Hård daglig budget: TRIAD_DAILY_BUDGET secret (default 50). Räknas i
// public.triad_budget_log via RPC triad_budget_claim. Nollställs varje
// dygn av att current_date byter (RPC upsertar per dag).
//
// Kostnad: ~$0.046/anrop × 50/dag = $2.30/dag = ~$70/månad.
//
// Prompten och model-versionen är DUPLICERADE från pipeline och
// triad-on-demand — synk-kritiskt.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { buildTriadPrompt, parseLabeledProse, validateTriad, fieldsToDbUpdate } from '../_shared/labeled-triad.ts'

const SB_URL         = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SERVICE_ROLE_KEY') || ''
const ANTHROPIC_KEY  = Deno.env.get('ANTHROPIC_API_KEY') || ''
const supabase = createClient(SB_URL, SB_SERVICE_KEY, { auth: { persistSession: false } })

const TRIAD_DAILY_BUDGET = parseInt(Deno.env.get('TRIAD_DAILY_BUDGET') || '50', 10)
const HARD_TIMEOUT_MS    = 120000            // 120s wall = 2 Sonnet-analyser (~63s × 2 + overhead) inom
                                             // 150s edge-cap med ~15s buffer. 30s (tidigare värde) lämnade
                                             // 100+s outnyttjat och begränsade oss till 1 analys/tick trots
                                             // budget 50/dag. Med 120s blir dagsbudgeten bindande i stället
                                             // för timeouten. Om Sonnet-latensen sjunker till ~15s hinner
                                             // fler iterationer per tick — budgeten stannar den ändå.
const LOCK_TIMEOUT_MS    = 5 * 60 * 1000     // 5 min stale lock cutoff

const CORS = { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/json' }
function json(body: any, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: CORS })
}

// Prompt-format, parser, validering och DB-mapping ligger i
// ../_shared/labeled-triad.ts.
async function runTriad(article: any): Promise<ReturnType<typeof parseLabeledProse> | null> {
  try {
    const prompt = buildTriadPrompt(article)
    const resp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-api-key': ANTHROPIC_KEY, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({ model: 'claude-sonnet-4-6', max_tokens: 4000, messages: [{ role: 'user', content: prompt }] })
    })
    if (!resp.ok) {
      console.log('Sonnet error:', resp.status, (await resp.text()).slice(0, 300))
      return null
    }
    const d = await resp.json()
    const rawText = (d.content?.[0]?.text || '').trim()
    return parseLabeledProse(rawText)
  } catch (e: any) {
    console.log('runTriad exception:', e.message)
    return null
  }
}

// ─── Handler ─────────────────────────────────────────────────────────────────
Deno.serve(async () => {
  const startedAt = Date.now()

  // 1. Kolla dagsbudget innan vi ens läser kandidater. RPC:n är atomic,
  //    men vi vill inte spränga limit + concurrent-invocations.
  const today = new Date().toISOString().slice(0, 10)
  const { data: budgetLog } = await supabase.from('triad_budget_log')
    .select('count').eq('day', today).maybeSingle()
  const usedTodayInit = budgetLog?.count || 0
  const budgetInitial = Math.max(0, TRIAD_DAILY_BUDGET - usedTodayInit)
  if (budgetInitial <= 0) {
    return json({
      ok: true, skipped: 'budget_exhausted',
      triad_calls_today: usedTodayInit,
      triad_budget_remaining: 0,
      duration_ms: Date.now() - startedAt
    })
  }

  // 2. Hämta kandidater
  const { data: candidates, error: cErr } = await supabase.rpc(
    'triad_background_candidates', { p_limit: budgetInitial }
  )
  if (cErr) return json({ ok: false, error: `candidates: ${cErr.message}` }, 500)
  if (!candidates?.length) {
    return json({
      ok: true, skipped: 'no_candidates',
      triad_calls_today: usedTodayInit,
      triad_budget_remaining: budgetInitial,
      duration_ms: Date.now() - startedAt
    })
  }

  // 3. Loop: atomic lock → budget claim → Sonnet → save/release.
  //    Sonnet är ~75s just nu, så i praktiken en artikel per invocation
  //    innan 100s HARD_TIMEOUT slår till. Cron kör var 30 min → 48 st
  //    invocations/dag ≈ 48 artiklar/dag under nuvarande Anthropic-latens.
  //    Om Sonnet blir snabbare igen (~15s) hinner vi 5-6 st per tick.
  let analyzed = 0, skipped_locked = 0, sonnet_errors = 0
  const staleCutoff = new Date(Date.now() - LOCK_TIMEOUT_MS).toISOString()

  for (const c of candidates) {
    // Wall-clock guard: sluta innan vi hamnar under 15s buffer mot edge-timeout
    if (Date.now() - startedAt > HARD_TIMEOUT_MS) {
      console.log('Approaching timeout, stopping early')
      break
    }

    // Atomic lock-reserv. Serialiserar mot triad-on-demand OCH andra
    // triad-background-invocations om cron råkar överlappa.
    const { data: locked, error: lockErr } = await supabase.from('articles')
      .update({ triad_pending: true, triad_pending_at: new Date().toISOString() })
      .eq('id', c.id)
      .or(`triad_pending.eq.false,triad_pending_at.lt.${staleCutoff}`)
      .select('id')
    if (lockErr) { console.log(`Lock error ${c.id}: ${lockErr.message}`); continue }
    if (!locked?.length) { skipped_locked++; continue }

    // Budget claim: atomic upsert. Om budget slut mitt i körningen
    // (annan invocation hann före) → släpp låset, break.
    const { data: bRemaining, error: bErr } = await supabase.rpc('triad_budget_claim', {
      p_budget: TRIAD_DAILY_BUDGET
    })
    if (bErr) {
      await supabase.from('articles').update({ triad_pending: false, triad_pending_at: null }).eq('id', c.id)
      console.log(`Budget claim error: ${bErr.message}`)
      break
    }
    if (bRemaining === -1) {
      await supabase.from('articles').update({ triad_pending: false, triad_pending_at: null }).eq('id', c.id)
      console.log('Budget exhausted mid-run, stopping')
      break
    }

    // Sonnet + parse + validering
    console.log(`Analyzing ${c.id.slice(0,8)} (max_rel=${c.max_rel}) — ${(c.title||'').slice(0,60)}`)
    const parsed = await runTriad(c)
    const parseError = parsed ? validateTriad(parsed) : 'sonnet failed'

    // Save + release lock i en update. Vid Sonnet-fel eller ofullständig
    // parse: budget är konsumerad men INGA fält skrivs — artikel återgår
    // till pool för nästa körning. Loggar orsaken för framtida audit.
    const update: Record<string, any> = { triad_pending: false, triad_pending_at: null }
    if (parsed && !parseError) {
      Object.assign(update, fieldsToDbUpdate(parsed.fields))
    } else {
      console.log(`TRIAD invalid ${c.id.slice(0,8)}: ${parseError}`,
        parsed ? { missing: parsed.missing.length, too_short: parsed.too_short.length, extra: parsed.extra.length } : {})
    }
    const { error: uErr } = await supabase.from('articles').update(update).eq('id', c.id)
    if (uErr) console.log(`Save error ${c.id}: ${uErr.message}`)

    if (parsed && !parseError) analyzed++
    else sonnet_errors++
  }

  // 4. Slutstatus
  const { data: finalLog } = await supabase.from('triad_budget_log')
    .select('count').eq('day', today).maybeSingle()
  const finalUsed = finalLog?.count || 0

  return json({
    ok: true,
    analyzed,
    skipped_locked,
    sonnet_errors,
    triad_calls_today: finalUsed,
    triad_budget_remaining: Math.max(0, TRIAD_DAILY_BUDGET - finalUsed),
    duration_ms: Date.now() - startedAt
  })
})
