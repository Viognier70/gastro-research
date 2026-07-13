// triad-on-demand
// ─────────────────────────────────────────────────────────────────────────────
// User-klick "Analysera genom TRIAD" mot en artikel utan imrad_methods.
// Kollar cache → lock → kvot; kör Sonnet 4.6 runTriad; skriver till DB;
// returnerar { status, quota_remaining, triad }.
//
// Låset (articles.triad_pending) förhindrar två concurrent Sonnet-anrop
// för samma artikel. Kvoten (triad_quota per user/månad, 3 för free,
// obegränsat för Pro) förhindrar cost-explosion per user. Analysen är
// permanent — en gång för alla, delas via DB.
//
// Autentisering server-side: JWT från Authorization-header valideras,
// user_id och is_pro hämtas från DB. Klienten kan inte sätta is_pro=true
// för att kringgå kvoten.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { buildTriadPrompt, parseLabeledProse, validateTriad, fieldsToDbUpdate } from '../_shared/labeled-triad.ts'

const SB_URL         = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SERVICE_ROLE_KEY') || ''
const ANTHROPIC_KEY  = Deno.env.get('ANTHROPIC_API_KEY') || ''
const supabase = createClient(SB_URL, SB_SERVICE_KEY, { auth: { persistSession: false } })

// CORS måste tillåta authorization + apikey + content-type i preflighten,
// annars faller browserns POST-anrop innan de når edge-fn. Buggen dolde sig
// tills frontend-CTA:n testades — cron/curl-tester behöver ingen preflight.
const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type':                 'application/json'
}
const LOCK_TIMEOUT_MS = 5 * 60 * 1000  // 5 min: stale lock tas över

function json(body: any, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: CORS })
}

// Prompt-format, parser, validering och DB-mapping ligger i
// ../_shared/labeled-triad.ts. Här handhas bara Sonnet-anropet och
// timing-instrumenteringen som ger nedbrytning av vad som tar tid.

type TriadTiming = {
  sonnet_ms: number
  parse_ms: number
  input_tokens?: number
  output_tokens?: number
  stop_reason?: string
  tokens_per_sec?: number
  sonnet_status?: number
  sonnet_error?: string
}

async function runTriad(article: any, maxTokens = 4000): Promise<{
  parsed: ReturnType<typeof parseLabeledProse> | null,
  timing: TriadTiming
}> {
  const t0 = Date.now()
  try {
    const prompt = buildTriadPrompt(article)

    const sonnetStart = Date.now()
    const resp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-api-key': ANTHROPIC_KEY, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({ model: 'claude-sonnet-4-6', max_tokens: maxTokens, messages: [{ role: 'user', content: prompt }] })
    })
    const sonnetMs = Date.now() - sonnetStart

    if (!resp.ok) {
      const errBody = await resp.text()
      console.log('Sonnet error:', resp.status, errBody.slice(0, 300))
      return {
        parsed: null,
        timing: { sonnet_ms: sonnetMs, parse_ms: 0, sonnet_status: resp.status, sonnet_error: errBody.slice(0, 200) }
      }
    }
    const parseStart = Date.now()
    const d = await resp.json()
    const rawText = (d.content?.[0]?.text || '').trim()
    const parsed = parseLabeledProse(rawText)
    const parseMs = Date.now() - parseStart

    const outTok = d.usage?.output_tokens
    const timing: TriadTiming = {
      sonnet_ms: sonnetMs,
      parse_ms: parseMs,
      input_tokens: d.usage?.input_tokens,
      output_tokens: outTok,
      stop_reason: d.stop_reason,
      tokens_per_sec: outTok && sonnetMs ? Math.round(outTok / (sonnetMs / 1000)) : undefined,
      sonnet_status: 200
    }
    return { parsed, timing }
  } catch (e: any) {
    console.log('runTriad exception:', e.message)
    return { parsed: null, timing: { sonnet_ms: Date.now() - t0, parse_ms: 0, sonnet_error: e.message } }
  }
}

// ─── Handler ─────────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  if (req.method !== 'POST')    return json({ status: 'error', error: 'POST required' }, 405)

  const startedAt = Date.now()

  // 1. Auth: JWT krävs. Anon avvisas → frontend redirigerar till sign-in.
  const authHeader = req.headers.get('Authorization') || ''
  const jwt = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : ''
  if (!jwt) return json({ status: 'unauthorized', error: 'sign in required' }, 401)
  const { data: userData, error: authErr } = await supabase.auth.getUser(jwt)
  if (authErr || !userData?.user) {
    return json({ status: 'unauthorized', error: 'sign in required' }, 401)
  }
  const userId = userData.user.id

  // 2. is_pro server-side. Klienten kan inte sätta detta.
  const { data: profile } = await supabase.from('profiles')
    .select('is_pro').eq('id', userId).maybeSingle()
  const isPro = !!profile?.is_pro

  // 3. Body. role (science-namn) styr vilka roll-specifika fält som
  //    returneras i svaret så frontend kan rendera inline direkt utan
  //    refetch — kritiskt för free-user som betalat kvot: get_articles_full
  //    är Pro-gate:ad, så refetch ger inget content utan Pro/trial. Vi
  //    vitlist:ar mot injection eftersom role interpoleras i .select()-strängen.
  //    test_max_tokens är ett tillfälligt diagnostikfält.
  const body = await req.json().catch(() => ({}))
  const { article_id } = body
  if (!article_id) return json({ status: 'error', error: 'missing article_id' }, 400)
  const VALID_ROLES = new Set(['sensory_pro','culinary_pro','gastronomy_culture','hospitality_mgmt','educator_researcher'])
  const role = VALID_ROLES.has(String(body.role || '')) ? String(body.role) : 'sensory_pro'
  const testMaxTokens = Math.max(500, Math.min(4000, Number(body.test_max_tokens) || 4000))

  // 4. Läs artikel
  const { data: article, error: aErr } = await supabase.from('articles')
    .select('id, title, abstract, insight, imrad_methods, triad_pending, triad_pending_at')
    .eq('id', article_id).maybeSingle()
  if (aErr || !article) return json({ status: 'error', error: 'article not found' }, 404)

  // 5. Cache-hit. Ingen kvot, ingen låsning. Hämta content för aktiv roll
  //    så frontend kan rendera direkt — annars skulle free-user se sin
  //    just-analyserade artikel som "no TRIAD yet" när de öppnar den igen.
  if (article.imrad_methods) {
    const { data: content } = await supabase.from('articles')
      .select(`imrad_introduction, imrad_methods, imrad_results, imrad_discussion, knowledge_explanation, episteme_${role}, techne_${role}, phronesis_${role}`)
      .eq('id', article_id).maybeSingle()
    return json({
      status: 'cached',
      duration_ms: Date.now() - startedAt,
      role,
      triad: {
        knowledge_explanation: content?.knowledge_explanation || null,
        imrad_introduction:    content?.imrad_introduction    || null,
        imrad_methods:         content?.imrad_methods         || null,
        imrad_results:         content?.imrad_results         || null,
        imrad_discussion:      content?.imrad_discussion      || null,
        episteme:              (content as any)?.[`episteme_${role}`]  || null,
        techne:                (content as any)?.[`techne_${role}`]    || null,
        phronesis:             (content as any)?.[`phronesis_${role}`] || null,
      }
    })
  }

  // 6. Lock-check. Annan invocation kör redan → klienten pollar. Detta
  //    är bara en snabb informationskoll för att returnera pending_since_ms
  //    utan onödigt DB-arbete. Den ATOMIC lock-reserven i steg 7 är det
  //    som faktiskt förhindrar race — se kommentar där.
  if (article.triad_pending) {
    const lockAge = article.triad_pending_at
      ? Date.now() - new Date(article.triad_pending_at).getTime()
      : Infinity
    if (lockAge < LOCK_TIMEOUT_MS) {
      return json({ status: 'pending', pending_since_ms: Math.round(lockAge) })
    }
    console.log(`Stale lock (${Math.round(lockAge / 1000)}s) on ${article_id}, taking over`)
  }

  // 7. ATOMIC lock-reserv. Postgres UPDATE ... WHERE serialiserar radlåset,
  //    så bara EN concurrent invocation kan lyckas. Vi accepterar takeover
  //    om triad_pending redan är false (normalfall) ELLER om låset är
  //    staltalt (>LOCK_TIMEOUT_MS gammalt). Om ingen rad returneras har
  //    en annan invocation just tagit låset → returnera 'pending'.
  //    Denna atomic check är det som förhindrar dubbla Sonnet-anrop, INTE
  //    steg 6 (som är race-käns­lig — läser + agerar med gap emellan).
  const staleCutoff = new Date(Date.now() - LOCK_TIMEOUT_MS).toISOString()
  const { data: lockedRows, error: lockErr } = await supabase.from('articles')
    .update({ triad_pending: true, triad_pending_at: new Date().toISOString() })
    .eq('id', article_id)
    .or(`triad_pending.eq.false,triad_pending_at.lt.${staleCutoff}`)
    .select('id')
  if (lockErr) return json({ status: 'error', error: `lock: ${lockErr.message}` }, 500)
  if (!lockedRows?.length) {
    return json({ status: 'pending', pending_since_ms: 0 })
  }

  // 8. Kvot-claim EFTER lås. Anthropic-cost är gate:ad bakom både lock och
  //    quota — lock först eftersom ingen skulle vara ute efter att analysera
  //    en artikel som just blir analyserad. Vid Sonnet-fel konsumeras kvot
  //    ändå (accepterat trade-off — release-RPC läggs till om fel-frekvens
  //    blir hög). Om kvot slut → RELEASE lock innan return.
  const { data: qRemaining, error: qErr } = await supabase.rpc('triad_quota_claim', {
    p_user_id: userId, p_is_pro: isPro
  })
  if (qErr) {
    await supabase.from('articles').update({ triad_pending: false, triad_pending_at: null }).eq('id', article_id)
    return json({ status: 'error', error: `quota_claim: ${qErr.message}` }, 500)
  }
  if (qRemaining === -1) {
    await supabase.from('articles').update({ triad_pending: false, triad_pending_at: null }).eq('id', article_id)
    return json({ status: 'quota_exceeded', quota_remaining: 0 }, 402)
  }

  // 9. Kör TRIAD (5-15s under normal Sonnet-load; 60-80s just nu vid ~40 tok/s)
  const { parsed, timing } = await runTriad(article, testMaxTokens)

  // 10. Sonnet-fel eller ofullständig parse: släpp lock (kvoten redan
  //     konsumerad). Frontend visar tydligt fel och retryar INTE automatiskt.
  //     ValidateTriad returnerar en fel-sträng om något label saknas eller
  //     är för kort — vi skriver då INTE halva data till DB.
  const parseError = parsed ? validateTriad(parsed) : (timing.sonnet_error || 'sonnet failed')
  if (!parsed || parseError) {
    await supabase.from('articles')
      .update({ triad_pending: false, triad_pending_at: null })
      .eq('id', article_id)
    console.log(`TRIAD invalid article=${article_id} user=${userId}: ${parseError}`,
      parsed ? { missing: parsed.missing, too_short: parsed.too_short.map(t => t.label), extra: parsed.extra } : {})
    return json({
      status: 'error',
      error: parseError || 'incomplete TRIAD analysis',
      missing: parsed?.missing || null,
      too_short: parsed?.too_short.map(t => t.label) || null,
      extra: parsed?.extra || null,
      quota_remaining: qRemaining,
      duration_ms: Date.now() - startedAt,
      timing
    }, 502)
  }

  // 11. Success: skriv alla fält + släpp lock i EN update.
  const update: Record<string, any> = {
    triad_pending: false,
    triad_pending_at: null,
    ...fieldsToDbUpdate(parsed.fields),
  }
  const { error: uErr } = await supabase.from('articles').update(update).eq('id', article_id)
  if (uErr) return json({ status: 'error', error: `save: ${uErr.message}`, timing }, 500)

  // Roll-specifika fält från parsed.fields så free-user som betalade
  // kvot kan se sin analys direkt utan att refetch via Pro-gate:ad
  // get_articles_full. Formatet i parsed.fields: EPISTEME_SENSORY_PRO etc.
  const upperRole = role.toUpperCase()
  return json({
    status: 'analyzed',
    quota_remaining: qRemaining,
    duration_ms: Date.now() - startedAt,
    role,
    timing,
    triad: {
      knowledge_explanation: parsed.fields.KNOWLEDGE_EXPLANATION      || null,
      imrad_introduction:    parsed.fields.IMRAD_INTRODUCTION         || null,
      imrad_methods:         parsed.fields.IMRAD_METHODS              || null,
      imrad_results:         parsed.fields.IMRAD_RESULTS              || null,
      imrad_discussion:      parsed.fields.IMRAD_DISCUSSION           || null,
      episteme:              parsed.fields[`EPISTEME_${upperRole}`]   || null,
      techne:                parsed.fields[`TECHNE_${upperRole}`]     || null,
      phronesis:             parsed.fields[`PHRONESIS_${upperRole}`]  || null,
    }
  })
})
