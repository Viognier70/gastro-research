// _shared/embedding-text.ts
// ─────────────────────────────────────────────────────────────────────────────
// Delad text-invariant för embedding-generation. Både edge-fn:en
// (generate-embeddings) och catchup-scriptet (scripts/batch-embed-catchup.ts)
// importerar denna modul så vektorrummet aldrig kan drifta mellan två
// oberoende kopior av string-logiken.
//
// KRITISKT: ändras något här — text-ordning, TEXT_SLICE, kolumnval — blir
// nyproducerade vektorer inkompatibla med tidigare. Semantic-search-scores
// meningslösa över gränsen. Om semantiken MÅSTE ändras: dokumentera skiftet
// och kör om hela populationen (37k+ artiklar via batch-embed-catchup).
//
// Bytes-identity mot legacy edge-fn-inline (generate-embeddings/index.ts:54-60
// per 2026-07-24) är verifierad av scripts/verify-embedding-text-refactor.ts
// mot 200 slumpade artiklar.
// ─────────────────────────────────────────────────────────────────────────────

// Per-text-cap (säkerhetsbälte). Största observerade i DB idag är ~6 220 tecken;
// 8 000 ger marginal utan att blåsa OpenAI:s 300k-tokens/anrop-cap när CHUNK=300.
export const TEXT_SLICE = 8000

// Kolumnlistan för SELECT — hålls här så SELECT-fält och text-byggaren aldrig
// kan drifta isär. Använd som .select(EMBEDDING_COLUMNS.join(',')) i klient
// eller EMBEDDING_COLUMNS.join(', ') i handskriven SQL.
export const EMBEDDING_COLUMNS = [
  'id',
  'title', 'core_claim', 'topic',
  'episteme_sensory_pro',
  'episteme_culinary_pro',
  'episteme_gastronomy_culture',
  'episteme_hospitality_mgmt',
  'episteme_educator_researcher',
] as const

// Fälten som går in i embedding-texten (alla utom id).
export type EmbeddingSource = {
  title: string | null
  core_claim: string | null
  topic: string | null
  episteme_sensory_pro: string | null
  episteme_culinary_pro: string | null
  episteme_gastronomy_culture: string | null
  episteme_hospitality_mgmt: string | null
  episteme_educator_researcher: string | null
}

// Bygg embedding-input-text. filter(Boolean) släpper null/undefined/'' (och
// number 0, false — men fälten är strings så det spelar ingen praktisk roll),
// join med enkelt mellanslag, slice till TEXT_SLICE. INTE trim, INTE lowercase,
// INTE deduplicering — bevara byte-identity med legacy edge-fn-logik.
export function buildEmbeddingText(a: EmbeddingSource): string {
  return [
    a.title, a.core_claim, a.topic,
    a.episteme_sensory_pro, a.episteme_culinary_pro, a.episteme_gastronomy_culture,
    a.episteme_hospitality_mgmt, a.episteme_educator_researcher,
  ].filter(Boolean).join(' ').slice(0, TEXT_SLICE)
}
