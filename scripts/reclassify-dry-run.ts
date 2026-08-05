// scripts/reclassify-dry-run.ts
// ────────────────────────────────────────────────────────────────────────────
// Kör reclassify_dry_run-RPC:n via service_role med lång timeout — Supabase
// SQL-editorn tar "Failed to fetch" på scenario b/c/d eftersom title-
// matchningen (3.8M substring-sökningar) tar längre än editorns proxy tål.
//
// REST-API:et via service_role har längre tolerans. Kombinerat med
// statement_timeout=15min på funktionen (migration 20260805190000) ska
// scenarier b/c/d gå igenom.
//
// USAGE:
//   export SERVICE_ROLE_KEY=<key>
//   deno run --allow-net --allow-env scripts/reclassify-dry-run.ts
//
//   # Anpassa target-topic:
//   deno run --allow-net --allow-env scripts/reclassify-dry-run.ts \
//     --old-topic=uncategorized
//
//   # Bara ett scenario:
//   deno run --allow-net --allow-env scripts/reclassify-dry-run.ts \
//     --only=d --sample=20
//
// FLAGGOR:
//   --old-topic=<topic>   default 'gastronomy'
//   --scenarios=a,b,c,d   default 'b,c,d' (skippa A — scenario a fungerar i editorn)
//   --only=<s>            alias för --scenarios=<s>
//   --sample=<n>          default 0 (bara aggregat). Sätts på sista scenariet.
//
// Skriver ut moved / to_uncategorized / distribution / sample per scenario.
// Ingen DB-skrivning.
// ────────────────────────────────────────────────────────────────────────────

const SB_URL = Deno.env.get('SUPABASE_URL') || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_KEY = Deno.env.get('SERVICE_ROLE_KEY') || ''
if (!SB_KEY) { console.error('SERVICE_ROLE_KEY env-var saknas'); Deno.exit(2) }

const args = Deno.args
const getArg = (name: string, def = '') => {
  const a = args.find(x => x.startsWith(`--${name}=`))
  return a ? a.split('=').slice(1).join('=') : def
}

const OLD_TOPIC = getArg('old-topic', 'gastronomy')
const SCENARIOS = (getArg('only') || getArg('scenarios', 'b,c,d')).split(',').map(s => s.trim().toLowerCase()).filter(Boolean)
const SAMPLE_N  = parseInt(getArg('sample', '0'), 10) || 0
const TIMEOUT_MS = 15 * 60 * 1000  // 15 min, matchar statement_timeout

type Distribution = { topic: string; before: number; after: number; delta: number }
type SampleRow = { title: string; old_topic: string; new_topic: string; matched: string[]; kw_len: number }
type ScenarioResult = {
  scenario: string
  target_population: number
  moved: number
  unchanged: number
  to_uncategorized: number
  distribution: Distribution[]
  sample: SampleRow[]
}

async function runScenario(oldTopic: string, sampleN: number, scenario: string): Promise<ScenarioResult> {
  const controller = new AbortController()
  const t = setTimeout(() => controller.abort(), TIMEOUT_MS)
  try {
    const r = await fetch(`${SB_URL}/rest/v1/rpc/reclassify_dry_run`, {
      method: 'POST',
      headers: {
        apikey: SB_KEY,
        Authorization: `Bearer ${SB_KEY}`,
        'Content-Type': 'application/json',
        // Ingen räknar via Prefer=count — vi läser bara JSONB-return.
      },
      body: JSON.stringify({ p_old_topic: oldTopic, p_sample_n: sampleN, p_scenario: scenario }),
      signal: controller.signal,
    })
    if (!r.ok) {
      throw new Error(`HTTP ${r.status}: ${(await r.text()).slice(0, 500)}`)
    }
    return await r.json() as ScenarioResult
  } finally {
    clearTimeout(t)
  }
}

function fmt(n: number): string { return n.toString().padStart(6) }
function fmtDelta(n: number): string {
  const s = (n >= 0 ? '+' : '') + n.toString()
  return s.padStart(8)
}
function pad(s: string, w: number): string {
  if (s.length >= w) return s.slice(0, w - 1) + '…'
  return s + ' '.repeat(w - s.length)
}

async function main() {
  console.log(`\nTarget topic:  ${OLD_TOPIC}`)
  console.log(`Scenarios:     ${SCENARIOS.join(', ')}`)
  console.log(`Sample-N:      ${SAMPLE_N} (sätts på sista scenariet)`)
  console.log(`Client timeout: ${TIMEOUT_MS / 1000}s\n`)

  for (let i = 0; i < SCENARIOS.length; i++) {
    const scenario = SCENARIOS[i]
    const isLast = i === SCENARIOS.length - 1
    const sampleN = isLast ? SAMPLE_N : 0

    console.log('─'.repeat(72))
    console.log(`SCENARIO ${scenario.toUpperCase()}`)
    console.log('─'.repeat(72))

    const started = Date.now()
    let result: ScenarioResult
    try {
      result = await runScenario(OLD_TOPIC, sampleN, scenario)
    } catch (e) {
      console.error(`  ERROR: ${(e as Error).message}`)
      console.error(`  duration till fel: ${((Date.now() - started) / 1000).toFixed(1)}s`)
      continue
    }
    const elapsed = ((Date.now() - started) / 1000).toFixed(1)

    console.log(`  duration:          ${elapsed}s`)
    console.log(`  target_population: ${result.target_population}`)
    console.log(`  moved:             ${result.moved}`)
    console.log(`  unchanged:         ${result.unchanged}`)
    console.log(`  to_uncategorized:  ${result.to_uncategorized}`)
    console.log('')

    // Top 15 topics by |delta| — beskär till läsbart
    const top = (result.distribution || []).slice(0, 15)
    console.log(`  Distribution (top 15 by |delta|):`)
    console.log(`    ${pad('topic', 30)} ${'before'.padStart(6)} ${'after'.padStart(6)} ${'delta'.padStart(8)}`)
    for (const d of top) {
      console.log(`    ${pad(d.topic, 30)} ${fmt(d.before)} ${fmt(d.after)} ${fmtDelta(d.delta)}`)
    }
    console.log('')

    if (result.sample?.length) {
      console.log(`  Sample (${result.sample.length}):`)
      for (const s of result.sample) {
        console.log(`    old=${s.old_topic}  →  new=${s.new_topic}  (kw_len=${s.kw_len})`)
        console.log(`      title:   ${(s.title || '').slice(0, 120)}`)
        console.log(`      matched: ${(s.matched || []).slice(0, 6).join(', ')}${(s.matched || []).length > 6 ? ' …' : ''}`)
      }
    }
    console.log('')
  }
}

main().catch(e => { console.error(e); Deno.exit(1) })
