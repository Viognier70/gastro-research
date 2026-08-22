// scripts/extract-repaired-ids.ts
// ─────────────────────────────────────────────────────────────────────────
// ORDER 111 (2026-08-20) — extraherar id-listan över artiklar som
// ORDER 109 faktiskt reparerade (outcome = wrote) från
// out/repair-abstracts.md. Matar batch-regen-triad.ts via --ids-flaggan.
//
// KÖRNING:
//   deno run --allow-read --allow-write scripts/extract-repaired-ids.ts
// UTMATNING:
//   out/repaired-ids.txt — en UUID per rad (dedupad, ordning bevarad)
// ─────────────────────────────────────────────────────────────────────────

const IN_PATH  = 'out/repair-abstracts.md'
const OUT_PATH = 'out/repaired-ids.txt'

const md = await Deno.readTextFile(IN_PATH)

// Matchar per-rad-tabellrader där outcome = wrote:
//   | `<uuid>` | <old_len> | <new_len> | +<gained> | `wrote` |  |
const re = /^\| `([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})` \|.*\| `wrote` \|/gm

const ids: string[] = []
let m: RegExpExecArray | null
while ((m = re.exec(md)) !== null) ids.push(m[1])

const unique = [...new Set(ids)]
await Deno.writeTextFile(OUT_PATH, unique.join('\n') + '\n')

console.log(`Read ${IN_PATH}`)
console.log(`Extracted ${ids.length} wrote-rows (${unique.length} unique) → ${OUT_PATH}`)
