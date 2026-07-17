// Delad konfiguration för OpenAlex-concepts → keywords-mappning.
// Används av daily-fetch (framåt-fix, Del 2) och backfill-openalex-concepts
// (Del 3 — 13 620 no-role-artiklar). EN PLATS för trösklarna så nya och
// backfillade artiklar får identisk keyword-kvalitet.
//
// Konstanterna kan skruvas efter Del 3-utfallet (se
// gustema-relevans-lager1-deployplan.md); ändring här träffar båda
// kod-vägar vid nästa deploy.

export const CONCEPT_LEVEL_MIN = 2   // OpenAlex-hierarki: 0=root, 6=leaf.
                                     // L0-1 = brus ("Chemistry", "Biology"),
                                     // L≥2 = användbart ("Fermentation").
export const CONCEPT_SCORE_MIN = 0.3 // OpenAlex classifier confidence 0-1.
                                     // <0.3 = låg confidence, filtreras bort.

// Rå OpenAlex-concept: {display_name, level, score, wikidata, id, ...}
export interface OpenAlexConcept {
  display_name?: string
  level?: number
  score?: number
}

// Filtrerar concepts efter tröskel och returnerar display_name-strängar,
// case-insensitive deduperade. Tom array om input null/tomt/felformad.
export function conceptsToKeywords(concepts: OpenAlexConcept[] | null | undefined): string[] {
  if (!Array.isArray(concepts)) return []
  const seen = new Map<string, string>()
  for (const c of concepts) {
    if ((c.level ?? 0) < CONCEPT_LEVEL_MIN) continue
    if ((c.score ?? 0) < CONCEPT_SCORE_MIN) continue
    const name = (c.display_name || '').trim()
    if (!name) continue
    const key = name.toLowerCase()
    if (!seen.has(key)) seen.set(key, name)
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
