// health-alert
// ─────────────────────────────────────────────────────────────────────────────
// Var 30:e min: läs gusto_health + räkna affil-kön direkt, SMS-larma via
// Brevo transactional SMS om något jobb har stannat med kö kvar. Cooldown
// 24h per larmtyp via public.alert_log.
//
// NULL-guard: bara literal 0 på takt-signalen larmar. NULL = signal saknas
// (vyn trasig, kolumn borta) — larma inte, annars spammar vi vid varje
// operationell drift i vyn.
//
// Larmtyper (2 st initialt; utöka via ALERTS-arrayen):
//   abstract_stalled: abstract_takt_1h = 0 AND abstract_kvar_att_hamta > 1000
//   affil_stalled:    affil_takt_1h    = 0 AND affil-kö (räknad live)   > 1000
//
// Test: sänk trösklarna i ALERTS tillfälligt (t.ex. queueMin: 0, taktMustBe:
// null) för att tvinga utskick. Återställ efter verifierat SMS.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SB_URL = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SERVICE_ROLE_KEY') || ''
const BREVO_KEY      = Deno.env.get('BREVO_API_KEY') || ''
const SMS_RECIPIENT  = Deno.env.get('ALERT_SMS_RECIPIENT') || ''
const SMS_SENDER     = 'GustoSci'  // Brevo alphanumeric, max 11 tecken

// Test-flagga. När '1' tvingas abstract_stalled att fyra oavsett signal-
// värden — allt annat (cooldown, upsert, Brevo-call) körs som vanligt.
// Default av. Rensa/sätt till annat värde än '1' för produktionsläge.
const TEST_FORCE_FIRE = Deno.env.get('TEST_FORCE_FIRE') === '1'

const COOLDOWN_HOURS = 24

const supabase = createClient(SB_URL, SB_SERVICE_KEY, { auth: { persistSession: false } })

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Content-Type': 'application/json'
}

// ─────────────────────────────────────────────────────────────────────────────
// Hjälpare
// ─────────────────────────────────────────────────────────────────────────────

// number|null-coercion. Postgres bigint kan komma som sträng via
// supabase-js — vi vill ha en normaliserad numerisk pipeline så att
// `= 0`-checken nedan inte kan luras av typ-brus.
function toNum(v: unknown): number | null {
  if (v === null || v === undefined) return null
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}

// Strikt "= 0"-villkor per spec: aldrig <= 0, aldrig negation. NULL/
// icke-numeriskt returnerar false och larmar därmed INTE.
function isLiteralZero(v: number | null): boolean {
  return v !== null && v === 0
}

// Kompakt siffra för SMS-text. 125000 -> "125k", 1_400_000 -> "1.4M".
function fmtCompact(n: unknown): string {
  const num = Number(n)
  if (!Number.isFinite(num)) return '?'
  if (num >= 1_000_000) return `${(num / 1_000_000).toFixed(1)}M`
  if (num >= 1000)      return `${Math.round(num / 1000)}k`
  return String(Math.trunc(num))
}

async function inCooldown(alertType: string): Promise<boolean> {
  const { data, error } = await supabase
    .from('alert_log')
    .select('last_sent')
    .eq('alert_type', alertType)
    .maybeSingle()
  if (error) throw new Error(`alert_log select ${alertType}: ${error.message}`)
  if (!data) return false
  const ageMs = Date.now() - new Date(data.last_sent).getTime()
  return ageMs < COOLDOWN_HOURS * 3600 * 1000
}

async function markSent(alertType: string): Promise<void> {
  const { error } = await supabase
    .from('alert_log')
    .upsert(
      { alert_type: alertType, last_sent: new Date().toISOString() },
      { onConflict: 'alert_type' }
    )
  if (error) throw new Error(`alert_log upsert ${alertType}: ${error.message}`)
}

async function sendSms(text: string): Promise<{ ok: boolean, status: number, body: any }> {
  const resp = await fetch('https://api.brevo.com/v3/transactionalSMS/sms', {
    method: 'POST',
    headers: { 'api-key': BREVO_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      sender:    SMS_SENDER,
      recipient: SMS_RECIPIENT,
      content:   text,
      type:      'transactional',
    }),
  })
  const body = await resp.json().catch(() => ({}))
  return { ok: resp.ok, status: resp.status, body }
}

// ─────────────────────────────────────────────────────────────────────────────
// Larmdefinition — signaler evalueras av evaluate(), text byggs av message()
// ─────────────────────────────────────────────────────────────────────────────

type SignalBundle = {
  abstractTakt:      number | null
  abstractQueue:     number | null
  affilTakt:         number | null
  affilQueue:        number | null
  relevanceTakt:     number | null
  unjudgedNow:       number | null      // obedomd_ko just nu
  unjudgedThen:      number | null      // obedomd_ko ~2h sedan (från queue_snapshots)
  unjudgedGrowth:    number | null      // now - then, för sms-texten
}

type AlertSpec = {
  type:      string
  fires:     (s: SignalBundle) => boolean
  message:   (s: SignalBundle) => string
}

const ALERTS: AlertSpec[] = [
  {
    type: 'abstract_stalled',
    fires: (s) =>
      isLiteralZero(s.abstractTakt) &&
      s.abstractQueue !== null && s.abstractQueue > 1000,
    // ASCII-only, ett GSM7-segment (~114 tecken med "999k"). fmtCompact
    // slår om till "X.YM" vid >=1_000_000 (samma längd).
    message: (s) =>
      `GUSTO alert: abstract backfill stalled. Rate 0/h, queue ${fmtCompact(s.abstractQueue)}. Check cron job + edge fn + OpenAlex/Anthropic quota.`,
  },
  {
    type: 'affil_stalled',
    fires: (s) =>
      isLiteralZero(s.affilTakt) &&
      s.affilQueue !== null && s.affilQueue > 1000,
    // ASCII-only, ett GSM7-segment (~107 tecken med "999k").
    message: (s) =>
      `GUSTO alert: affiliation backfill stalled. Rate 0/h, queue ${fmtCompact(s.affilQueue)}. Check cron job + edge fn + OpenAlex quota.`,
  },
  {
    type: 'relevance_stalled',
    // Samma mönster som ovan: takt = literal 0 (NULL larmar inte) AND
    // kö > 1000. Fångar "cron är död" / "edge fn kraschar direkt".
    fires: (s) =>
      isLiteralZero(s.relevanceTakt) &&
      s.unjudgedNow !== null && s.unjudgedNow > 1000,
    // ASCII-only, ett GSM7-segment (~115 tecken med "999k").
    message: (s) =>
      `GUSTO alert: relevance check stalled. Rate 0/h, queue ${fmtCompact(s.unjudgedNow)}. Check cron job + edge fn + Haiku quota.`,
  },
  {
    type: 'relevance_looping',
    // Fången: fn kör men skippar allt (Haiku returnerar null, predikat
    // matchar bara skräp, etc). Detekterar VÄXT kö sedan 2h sedan.
    // Kräver att queue_snapshots har en post ~2h gammal (health-alert
    // snapshotar varje 30min-tick). Om ingen historik finns eller den
    // är för färsk (<1h45min) skippas larmet — no false positives.
    fires: (s) =>
      s.unjudgedNow    !== null &&
      s.unjudgedThen   !== null &&
      s.unjudgedGrowth !== null && s.unjudgedGrowth > 100,
    // ASCII-only, ett GSM7-segment (~120 tecken med "+50k").
    message: (s) =>
      `GUSTO alert: relevance queue GROWING. Job running but not processing. +${fmtCompact(s.unjudgedGrowth)} in 2h. Check skip rate + predicate.`,
  },
]

// ─────────────────────────────────────────────────────────────────────────────
// Handler
// ─────────────────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  const startedAt = Date.now()

  if (!BREVO_KEY)
    return new Response(JSON.stringify({ ok: false, error: 'BREVO_API_KEY not set' }), { status: 500, headers: CORS })
  if (!SMS_RECIPIENT)
    return new Response(JSON.stringify({ ok: false, error: 'ALERT_SMS_RECIPIENT not set' }), { status: 500, headers: CORS })

  // 1. gusto_health via RPC get_gusto_health() — RPC:n har SET statement_timeout=30s
  //    så triad_misstankt_korta-subqueryn (20 length-checks × 10k rader) hinner
  //    klart. Direkt select från vyn hittar PostgREST-timeout (~3-8s) och timeoutar.
  const { data: rpcRows, error: hErr } = await supabase.rpc('get_gusto_health')
  if (hErr)
    return new Response(JSON.stringify({ ok: false, error: `gusto_health: ${hErr.message}` }), { status: 500, headers: CORS })
  const rows = (rpcRows as any[]) || []
  if (!rows.length)
    return new Response(JSON.stringify({ ok: false, error: 'gusto_health returned no rows' }), { status: 500, headers: CORS })
  const row = rows[0] as Record<string, any>

  // 2. Räkna affil-kön live. Head-count via count=exact + head=true.
  //    Definition: doi.org-artiklar utan institutions som inte redan
  //    försökts affilieras.
  const { count: affilQueueRaw, error: cErr } = await supabase
    .from('articles')
    .select('*', { count: 'exact', head: true })
    .is('institutions', null)
    .is('affiliation_attempted_at', null)
    .ilike('url', '%doi.org%')
  if (cErr)
    return new Response(JSON.stringify({ ok: false, error: `articles count: ${cErr.message}` }), { status: 500, headers: CORS })

  const unjudgedNow = toNum(row.obedomd_ko)

  // Läs snapshot ~2h sedan för looping-detektion. Vi kräver en post minst
  // 1h45min gammal (så vi jämför mot något som INTE precis snapshotades)
  // och inte äldre än 4h (annars är jämförelsen inte pålitlig — t.ex.
  // efter helg-outage). Om ingen matchande post finns är unjudgedThen
  // null och relevance_looping fires inte.
  let unjudgedThen: number | null = null
  const cutoffMax = new Date(Date.now() - 1.75 * 3600 * 1000).toISOString()  // 1h45min ago
  const cutoffMin = new Date(Date.now() - 4    * 3600 * 1000).toISOString()  // 4h ago
  const { data: snap } = await supabase.from('queue_snapshots')
    .select('value, ts')
    .eq('kind', 'obedomd_ko')
    .lt('ts', cutoffMax)
    .gt('ts', cutoffMin)
    .order('ts', { ascending: false })
    .limit(1)
    .maybeSingle()
  if (snap) unjudgedThen = toNum(snap.value)

  // Snapshota nuvarande kö för framtida jämförelser. Insert-och-glöm.
  if (unjudgedNow !== null) {
    await supabase.from('queue_snapshots').insert({ kind: 'obedomd_ko', value: unjudgedNow })
  }

  // Städa snapshots äldre än 7 dygn (mängden växer 48/dag = ~336/vecka).
  await supabase.from('queue_snapshots')
    .delete().lt('ts', new Date(Date.now() - 7 * 24 * 3600 * 1000).toISOString())

  const signals: SignalBundle = {
    abstractTakt:   toNum(row.abstract_takt_1h),
    abstractQueue:  toNum(row.abstract_kvar_att_hamta),
    affilTakt:      toNum(row.affil_takt_1h),
    affilQueue:     toNum(affilQueueRaw),
    relevanceTakt:  toNum(row.relevance_takt_1h),
    unjudgedNow,
    unjudgedThen,
    unjudgedGrowth: (unjudgedNow !== null && unjudgedThen !== null) ? (unjudgedNow - unjudgedThen) : null,
  }

  // 3. Utvärdera larm, respektera cooldown, skicka.
  const results: any[] = []
  for (const alert of ALERTS) {
    // TEST_FORCE_FIRE bypassar bara abstract_stalled — den är
    // determininistisk (läser vyn, ingen extra räkning) och räcker
    // för att verifiera hela pipelinen ända till telefonen.
    const forced = TEST_FORCE_FIRE && alert.type === 'abstract_stalled'
    if (!forced && !alert.fires(signals)) {
      results.push({ type: alert.type, action: 'no_fire' })
      continue
    }
    if (await inCooldown(alert.type)) {
      results.push({ type: alert.type, action: 'cooldown' })
      continue
    }
    const text = alert.message(signals)
    const sms  = await sendSms(text)
    if (!sms.ok) {
      results.push({ type: alert.type, action: 'send_failed', status: sms.status, body: sms.body })
      continue
    }
    await markSent(alert.type)
    results.push({ type: alert.type, action: 'sent', text, forced, message_id: sms.body?.messageId ?? null })
  }

  return new Response(JSON.stringify({
    ok: true,
    test_force_fire: TEST_FORCE_FIRE,
    signals,
    results,
    duration_ms: Date.now() - startedAt,
  }), { headers: CORS })
})
