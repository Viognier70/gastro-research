// scripts/rebuild-syntheses.ts
// ─────────────────────────────────────────────────────────────────────────
// ORDER 122 (2026-08-22): kör om research_syntheses för att fylla
// article_ids + korrigera evidence_type på legacy-rader.
//
// Bakgrund (state 2026-08-21 innan denna körning):
//   - 23 av 25 rader saknade article_ids (edge-fn skrev inte kolumnen förrän
//     idag; kolumnen fanns i schemat, backfillad på 2 rader manuellt)
//   - 2 rader (sensory_pro/flavor_science, culinary_pro/fermentation_science)
//     hade article_ids satta MEN evidence_type='divergence' motsäger deras
//     convergence-text — sannolikt backfill-bugg
//   - 1 rad smoke-testades efter deploy 2026-08-22 (sensory_pro/flavor_science)
//     och har nu nya kontraktet
//
// Detta skript invokar synthesize-edge-fn per (role, topic) — som gör ett
// Haiku-anrop och upsert:ar research_syntheses. Nya prompten (ORDER 122):
//   - Skriver article_ids från underlaget
//   - Whitelistar evidence_type via cleanEvidenceType
//   - divergence null när konvergens (cleanDivergence normaliserar)
//   - Underlag höjt till ~5000 chars totalt (10 × 400 chars core_claim)
//
// KÖRNING:
//   Dry-run (listar bara, inga anrop):
//     SUPABASE_SERVICE_ROLE_KEY=eyJ... \
//       deno run --allow-net --allow-env scripts/rebuild-syntheses.ts
//
//   Apply (invokar synthesize-edge-fn per par, ~$0.0016 per anrop):
//     SUPABASE_SERVICE_ROLE_KEY=eyJ... \
//       deno run --allow-net --allow-env scripts/rebuild-syntheses.ts --apply
//
//   Skip specifik(a) par (t.ex. smoke-testad rad du inte vill köra om):
//     ... rebuild-syntheses.ts --apply \
//       --skip sensory_pro/flavor_science
//
//   Kostnad: 25 pair × $0.0016 ≈ $0.04. Försumbart.
// ─────────────────────────────────────────────────────────────────────────

const SB_URL   = Deno.env.get('SUPABASE_URL') || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_KEY   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
const APPLY    = Deno.args.includes('--apply')
const PER_MS   = 300  // paus mellan invocations — Haiku rate-limits är
                      // generösa men vi behöver inte skynda oss

// Parse --skip role/topic (repeatable) → Set
const SKIPS: Set<string> = new Set()
for (let i = 0; i < Deno.args.length; i++) {
  if (Deno.args[i] === '--skip' && Deno.args[i + 1]) {
    SKIPS.add(Deno.args[i + 1])
  }
}

if (!SB_KEY) {
  console.error('Missing SUPABASE_SERVICE_ROLE_KEY')
  Deno.exit(2)
}

type Pair = {
  role:          string
  topic:         string
  key:           string
  hasIds:        boolean
  idCount:       number
  evidence_type: string | null
  updated_at:    string
}

async function fetchPairs(): Promise<Pair[]> {
  const params = new URLSearchParams()
  params.append('select', 'role,topic,article_ids,evidence_type,updated_at')
  params.append('order',  'role,topic')
  const r = await fetch(`${SB_URL}/rest/v1/research_syntheses?${params.toString()}`, {
    headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}` }
  })
  if (!r.ok) throw new Error(`fetchPairs ${r.status}: ${(await r.text()).slice(0, 200)}`)
  const rows: any[] = await r.json()
  return rows.map(row => ({
    role:          row.role,
    topic:         row.topic,
    key:           `${row.role}/${row.topic}`,
    hasIds:        Array.isArray(row.article_ids) && row.article_ids.length > 0,
    idCount:       Array.isArray(row.article_ids) ? row.article_ids.length : 0,
    evidence_type: row.evidence_type ?? null,
    updated_at:    row.updated_at,
  }))
}

type SynthResult = {
  ok:            boolean
  status:        number
  evidence_type: string | null
  divergence:    string | null
  error:         string | null
}

async function invokeSynthesize(role: string, topic: string): Promise<SynthResult> {
  try {
    const r = await fetch(`${SB_URL}/functions/v1/synthesize`, {
      method: 'POST',
      headers: {
        apikey:          SB_KEY,
        Authorization:   `Bearer ${SB_KEY}`,
        'Content-Type':  'application/json',
      },
      body: JSON.stringify({ role, topic }),
    })
    const data = await r.json().catch(() => ({}))
    if (!r.ok || !data?.ok) {
      return {
        ok: false, status: r.status,
        evidence_type: null, divergence: null,
        error: data?.error || `HTTP ${r.status}: ${JSON.stringify(data).slice(0, 100)}`,
      }
    }
    // Response: { ok: true, synthesis: { ... }, role, topic, article_count }
    const s = data.synthesis || {}
    return {
      ok: true, status: r.status,
      evidence_type: s.evidence_type ?? null,
      divergence:    s.divergence ?? null,
      error:         null,
    }
  } catch (e) {
    return {
      ok: false, status: 0,
      evidence_type: null, divergence: null,
      error: (e as Error).message,
    }
  }
}

async function main() {
  const startedAt = new Date().toISOString()
  console.log(`[start] mode=${APPLY ? 'APPLY (invokar synthesize-fn per par)' : 'DRY-RUN'}  at=${startedAt}`)

  const allPairs = await fetchPairs()
  const targets  = allPairs.filter(p => !SKIPS.has(p.key))
  const skipped  = allPairs.filter(p =>  SKIPS.has(p.key))

  console.log(`[fetch] ${allPairs.length} totalt, ${skipped.length} skippade, ${targets.length} att köra om`)
  if (skipped.length) console.log(`[skip] ${[...SKIPS].join(', ')}`)

  if (!APPLY) {
    console.log(`\nSka köras om (${targets.length} par):`)
    console.log(`  ${'role/topic'.padEnd(45)} ${'ids'.padEnd(8)} ${'evidence'.padEnd(14)} updated_at`)
    console.log(`  ${'-'.repeat(45)} ${'-'.repeat(8)} ${'-'.repeat(14)} ${'-'.repeat(19)}`)
    for (const p of targets) {
      const ids = p.hasIds ? `yes (${p.idCount})` : 'no'
      console.log(`  ${p.key.padEnd(45)} ${ids.padEnd(8)} ${(p.evidence_type ?? 'null').padEnd(14)} ${p.updated_at.slice(0, 19)}`)
    }
    console.log(`\n[dry-run] inga anrop. Kör om med --apply för att invokera synthesize.`)
    return
  }

  // APPLY: invokera per par, samla utfall
  const outcomes:      Record<string, number> = {}  // evidence_type → count
  const errorReasons:  Array<{key: string; error: string}> = []
  let sent           = 0
  let failed         = 0
  let hasDivergence  = 0

  console.log(``)
  for (let i = 0; i < targets.length; i++) {
    const p      = targets[i]
    const prefix = `[${(i + 1).toString().padStart(2)}/${targets.length}]`
    const res    = await invokeSynthesize(p.role, p.topic)
    if (res.ok) {
      sent++
      const et = res.evidence_type ?? 'unknown'
      outcomes[et] = (outcomes[et] || 0) + 1
      const hasDiv = !!(res.divergence && String(res.divergence).trim())
      if (hasDiv) hasDivergence++
      console.log(`${prefix} ${p.key.padEnd(45)} → ${et}${hasDiv ? ' + divergence' : ''}`)
    } else {
      failed++
      errorReasons.push({ key: p.key, error: res.error || 'unknown' })
      console.log(`${prefix} ${p.key.padEnd(45)} → FAIL ${res.error?.slice(0, 100) || 'unknown'}`)
    }
    await new Promise(res => setTimeout(res, PER_MS))
  }

  const finishedAt = new Date().toISOString()
  console.log(`\n[done] ${finishedAt}  sent=${sent} failed=${failed}`)

  console.log(`\n=== evidence_type-fördelning (${sent} lyckade) ===`)
  const sortedOutcomes = Object.entries(outcomes).sort((a, b) => b[1] - a[1])
  for (const [et, count] of sortedOutcomes) {
    const pct = Math.round(count * 100 / sent)
    console.log(`  ${et.padEnd(15)} ${count} (${pct}%)`)
  }

  console.log(`\n=== divergence-täckning ===`)
  console.log(`  Med divergence-text ifylld: ${hasDivergence} / ${sent} (${sent ? Math.round(hasDivergence * 100 / sent) : 0}%)`)
  console.log(`  Utan (null / convergence):  ${sent - hasDivergence}`)

  if (errorReasons.length) {
    console.log(`\n=== Fel (${errorReasons.length}) ===`)
    for (const { key, error } of errorReasons) {
      console.log(`  ${key}: ${error}`)
    }
  }
}

main().catch(e => { console.error('[FATAL]', e); Deno.exit(1) })
