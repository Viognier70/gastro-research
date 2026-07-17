// Delad konfiguration för OpenAlex-termer → keywords-mappning.
// Används av daily-fetch (framåt-fix, Del 2) och backfill-openalex-terms
// (Del 3). EN plats för logiken så nya och backfillade artiklar får identisk
// keyword-kvalitet.
//
// HYBRID (beslut 2026-07-17, Anders, mot data):
//   Primär   → OpenAlex topics + keywords (kuraterade fält, rena termer,
//              snittet ~5-8/artikel).
//   Fallback → OM primär < MIN_TERMS: fyll på med concepts filtrerade på
//              L>=2 + score>=0.3 tills MIN_TERMS nås eller concepts tar
//              slut. Undviker gles-fall (svans där topics+keywords ger 0-3
//              termer) utan att påtvinga concepts-bruset på artiklar som
//              redan är rena.
//
// MIN_TERMS är golv för hur många termer en artikel behöver för att kunna
// delta i keyword-nätverkets kopplingar. Skruvas här om Del 3 visar behov.

export const MIN_TERMS = 4

// Interna trösklar för fallback-poolen — bara aktiva när primär är gles.
// L0-1 = brus ("Chemistry", "Biology"); L>=2 = användbart ("Fermentation").
// Score < 0.3 = låg classifier confidence, filtreras bort.
const CONCEPT_LEVEL_MIN = 2
const CONCEPT_SCORE_MIN = 0.3

export interface OpenAlexTerm {
  display_name?: string
}

export interface OpenAlexConcept {
  display_name?: string
  level?: number
  score?: number
}

export interface OpenAlexWorkTerms {
  topics?: OpenAlexTerm[] | null
  keywords?: OpenAlexTerm[] | null
  concepts?: OpenAlexConcept[] | null
}

// Extraherar keywords från ett OpenAlex work med hybrid-strategi:
// primärt topics + keywords (dedup CI, bevarar första förekomstens stavning);
// om resultat < MIN_TERMS toppas med filtrerade concepts som fallback i den
// ordning OpenAlex returnerar dem (score-sorterade fallande — bästa först).
// Tom array om input null/tomt/felformad.
export function openAlexToKeywords(work: OpenAlexWorkTerms | null | undefined): string[] {
  if (!work) return []
  const seen = new Map<string, string>()
  const push = (name: string | undefined) => {
    const clean = (name || '').trim()
    if (!clean) return
    const key = clean.toLowerCase()
    if (!seen.has(key)) seen.set(key, clean)
  }

  // Primär: topics (bredare ankaretiketter) före keywords (precisare).
  if (Array.isArray(work.topics)) for (const t of work.topics) push(t?.display_name)
  if (Array.isArray(work.keywords)) for (const t of work.keywords) push(t?.display_name)

  // Fallback: bara om primär är gles.
  if (seen.size < MIN_TERMS && Array.isArray(work.concepts)) {
    for (const c of work.concepts) {
      if (seen.size >= MIN_TERMS) break
      if ((c.level ?? 0) < CONCEPT_LEVEL_MIN) continue
      if ((c.score ?? 0) < CONCEPT_SCORE_MIN) continue
      push(c.display_name)
    }
  }

  return Array.from(seen.values())
}

// Case-insensitive merge av flera keyword-listor. Bevarar första förekomstens
// stavning. Används av pipeline save() för att slå ihop OpenAlex-keywords
// (från daily-fetch INSERT, levererat via claim_pipeline_batch's row_to_json)
// med Haiku-genererade keywords (från runSci) utan att någon vinner-och-
// överskriver den andra.
//
// Fixar samtidigt buggen där `u.keywords = sci.keywords || []` skrev över
// befintliga keywords med tom array när Haiku returnerade tomt/parseerror.
export function mergeKeywordsCaseInsensitive(...lists: (string[] | null | undefined)[]): string[] {
  const seen = new Map<string, string>()
  for (const list of lists) {
    if (!Array.isArray(list)) continue
    for (const k of list) {
      if (typeof k !== 'string') continue
      const trimmed = k.trim()
      if (!trimmed) continue
      const key = trimmed.toLowerCase()
      if (!seen.has(key)) seen.set(key, trimmed)
    }
  }
  return Array.from(seen.values())
}
