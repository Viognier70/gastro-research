// health-mail
// ─────────────────────────────────────────────────────────────────────────────
// Dagligt hälsomail till Anders. Läser en rad ur gusto_health-vyn (service
// role, vyn timeoutar mot anon på grund av corpus-storleken), formaterar den
// till ett läsbart text-mail och skickar via Brevo — samma endpoint och
// BREVO_API_KEY-secret som weekly-newsletters admin-digest använder.
//
// LABEL_MAP och SECTION_ORDER är där man tunar utseendet utan att röra
// pipeline-logiken. Fält som saknas i mappen kastas inte bort — de renderas
// med auto-prettifierat namn i slutet så nya kolumner i vyn syns direkt.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SB_URL = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SERVICE_ROLE_KEY') || ''
const BREVO_KEY = Deno.env.get('BREVO_API_KEY') || ''
const supabase = createClient(SB_URL, SB_SERVICE_KEY, { auth: { persistSession: false } })

const RECIPIENT_EMAIL = 'anders@crichton-fock.com'
const RECIPIENT_NAME  = 'Anders'
const SENDER_EMAIL    = 'anders@crichton-fock.com'
const SENDER_NAME     = 'Gusto Science'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Content-Type': 'application/json'
}

// ─────────────────────────────────────────────────────────────────────────────
// Formatering
// ─────────────────────────────────────────────────────────────────────────────

type FieldSpec = {
  label: string
  format: (row: Record<string, any>) => string
}

// Svenska tusentalsavgränsare (mellanslag). "10 000" istället för "10,000".
function fmtInt(n: unknown): string {
  if (n === null || n === undefined || n === '') return '—'
  const num = Number(n)
  if (!Number.isFinite(num)) return String(n)
  return Math.trunc(num).toLocaleString('sv-SE').replace(/ /g, ' ')
}
function fmtPct(n: unknown): string {
  if (n === null || n === undefined || n === '') return '—'
  const num = Number(n)
  if (!Number.isFinite(num)) return String(n)
  return `${num.toFixed(1)}%`
}
function fmtPair(a: unknown, b: unknown, sep = ' / '): string {
  return `${fmtInt(a)}${sep}${fmtInt(b)}`
}
function fmtRange(a: unknown, b: unknown): string {
  const av = (a === null || a === undefined) ? '?' : String(a)
  const bv = (b === null || b === undefined) ? '?' : String(b)
  return `${av}–${bv}`
}

// LABEL_MAP — verifierat mot faktiska kolumnnamn i gusto_health-vyn
// 2026-07-09. Första test-sendens rå-JSON-block avslöjade svenska
// nycklar; mina engelska gissningar missade alla åtta. Nu låst mot
// vyns faktiska namn.
const FIELDS: Record<string, FieldSpec> = {
  kran_institution: {
    label: 'Kran (nya m. institution)',
    format: (r) => fmtPct(r.kran_pct_med_inst),
  },
  syntheses_rows_unique: {
    label: 'Synteser (rader/unika)',
    format: (r) => fmtPair(r.synt_rader, r.synt_unika),
  },
  svep_stale: {
    label: 'Svep ej körda >24h',
    format: (r) => fmtPair(r.svep_gamla, r.svep_totalt),
  },
  year_span: {
    label: 'Korpus årsspann',
    format: (r) => fmtRange(r.korpus_minar, r.korpus_maxar),
  },
  abstract_remaining: {
    label: 'Abstract kvar att hämta',
    format: (r) => fmtInt(r.abstract_kvar_att_hamta),
  },
  abstract_takt_1h: {
    label: 'Abstract-takt (1h)',
    format: (r) => fmtInt(r.abstract_takt_1h),
  },
  affil_takt_1h: {
    label: 'Affil-takt (1h)',
    format: (r) => fmtInt(r.affil_takt_1h),
  },
  relevance_takt_1h: {
    label: 'Relevance-takt (1h)',
    format: (r) => fmtInt(r.relevance_takt_1h),
  },
  unchecked_queue: {
    label: 'Obedömd kö',
    format: (r) => fmtInt(r.obedomd_ko),
  },
  unique_dois: {
    label: 'Unika DOI',
    format: (r) => fmtInt(r.unika_doi),
  },
  judged_relevant: {
    label: 'Bedömt relevanta',
    format: (r) => fmtInt(r.bedomt_relevanta),
  },
  triad_suspect_short: {
    label: 'TRIAD misstänkt korta',
    format: (r) => fmtInt(r.triad_misstankt_korta),
  },
}

// Sektioner: primära signaler överst, "copy-tal" separator, sedan mängder.
const SECTION_ORDER: Array<{ header?: string, keys: string[] }> = [
  { keys: [
      'kran_institution',
      'syntheses_rows_unique',
      'svep_stale',
      'year_span',
      'abstract_remaining',
      'unchecked_queue',
    ] },
  { header: 'Takt (1h)', keys: ['abstract_takt_1h', 'affil_takt_1h', 'relevance_takt_1h'] },
  { header: 'Copy-tal', keys: ['unique_dois', 'judged_relevant'] },
  { header: 'TRIAD-kvalitet', keys: ['triad_suspect_short'] },
]

// Nycklar som LABEL_MAP slår upp — används av responsen för att flagga
// om vyn någon dag börjar returnera ett fält vi inte känner igen. Om
// uncovered_keys blir icke-tom ska LABEL_MAP + denna set uppdateras i
// takt.
const COVERED_COLUMN_KEYS = new Set<string>([
  'kran_pct_med_inst',
  'synt_rader', 'synt_unika',
  'svep_gamla', 'svep_totalt',
  'korpus_minar', 'korpus_maxar',
  'abstract_kvar_att_hamta',
  'abstract_takt_1h', 'affil_takt_1h', 'relevance_takt_1h',
  'obedomd_ko',
  'unika_doi',
  'bedomt_relevanta',
  'triad_misstankt_korta',
])

function padRight(s: string, w: number): string {
  return s.length >= w ? s + '  ' : s + ' '.repeat(w - s.length)
}

function buildBody(row: Record<string, any>, isoDate: string): string {
  const LABEL_WIDTH = 30

  const lines: string[] = []
  lines.push(`Gusto hälsa — ${isoDate}`)
  lines.push('')

  for (const section of SECTION_ORDER) {
    if (section.header) {
      lines.push('')
      lines.push(`── ${section.header} ──`)
    }
    for (const key of section.keys) {
      const spec = FIELDS[key]
      if (!spec) continue
      lines.push(`${padRight(spec.label + ':', LABEL_WIDTH)}${spec.format(row)}`)
    }
  }

  return lines.join('\n')
}

// ─────────────────────────────────────────────────────────────────────────────
// Handler
// ─────────────────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  const startedAt = Date.now()

  if (!BREVO_KEY) {
    return new Response(
      JSON.stringify({ ok: false, error: 'BREVO_API_KEY not set' }),
      { status: 500, headers: CORS }
    )
  }

  // Via RPC get_gusto_health() istället för direkt view-select — RPC:n har
  // SET statement_timeout=30s så triad_misstankt_korta hinner klart.
  const { data: rpcRows, error: selectErr } = await supabase.rpc('get_gusto_health')

  if (selectErr) {
    return new Response(
      JSON.stringify({ ok: false, error: `get_gusto_health: ${selectErr.message}` }),
      { status: 500, headers: CORS }
    )
  }
  const rows = (rpcRows as any[]) || []
  if (!rows.length) {
    return new Response(
      JSON.stringify({ ok: false, error: 'gusto_health returned no rows' }),
      { status: 500, headers: CORS }
    )
  }

  const row = rows[0] as Record<string, any>
  const isoDate = new Date().toISOString().slice(0, 10)
  const body = buildBody(row, isoDate)

  // Brevo transactional email — samma endpoint som weekly-newsletter
  // admin-digest (v3/smtp/email). textContent istället för htmlContent
  // så mailet är ren monospace/text.
  const brevoResp = await fetch('https://api.brevo.com/v3/smtp/email', {
    method: 'POST',
    headers: { 'api-key': BREVO_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      sender:  { name: SENDER_NAME, email: SENDER_EMAIL },
      to:      [{ email: RECIPIENT_EMAIL, name: RECIPIENT_NAME }],
      subject: `Gusto hälsa ${isoDate}`,
      textContent: body,
      // Brevo kräver antingen textContent eller htmlContent; vi vill ha
      // monospace för siffror-justering. Wrapper-html som bevarar text
      // som <pre>-block så mailklienter renderar det korrekt.
      htmlContent: `<pre style="font-family:monospace,ui-monospace;font-size:13px;line-height:1.55;white-space:pre-wrap;color:#0C0B09;background:#F7F4ED;padding:16px;border-radius:8px">${
        body
          .replace(/&/g, '&amp;')
          .replace(/</g, '&lt;')
          .replace(/>/g, '&gt;')
      }</pre>`,
    }),
  })
  const brevoBody = await brevoResp.json().catch(() => ({}))
  const brevoOk = brevoResp.ok

  return new Response(JSON.stringify({
    ok: brevoOk,
    status: brevoResp.status,
    message_id: brevoBody.messageId || null,
    brevo_message: brevoBody.message || null,
    row_keys: Object.keys(row),
    uncovered_keys: Object.keys(row).filter(k => !COVERED_COLUMN_KEYS.has(k)),
    duration_ms: Date.now() - startedAt,
  }), { headers: CORS })
})
