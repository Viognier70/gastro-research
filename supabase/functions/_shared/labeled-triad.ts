// _shared/labeled-triad.ts
// ─────────────────────────────────────────────────────────────────────────────
// EN källa för TRIAD-analysens prompt-format, parser och validering.
// Importeras av pipeline, triad-on-demand och triad-background. Ändring
// här slår igenom överallt — sync-kritiskt-kommentaren i varje fn:s
// runTriad kan tas bort när denna modul används.
//
// Format: labeled prose istället för JSON. Skäl: (a) strömmar snyggt
// (ingen escape, inga citattecken), (b) frontend-parsing är trivial,
// (c) samma cost, ingen extra latens, (d) strict validering fångar
// halva analyser explicit i stället för att smyga igenom via
// recovery-parser.

export const ROLES = [
  'sensory_pro',
  'culinary_pro',
  'gastronomy_culture',
  'hospitality_mgmt',
  'educator_researcher',
] as const

export type Role = typeof ROLES[number]

// 4 IMRaD + 1 knowledge + 5 roller × 3 dimensioner = 20 fält.
export const EXPECTED_LABELS = [
  'KNOWLEDGE_EXPLANATION',
  'IMRAD_INTRODUCTION', 'IMRAD_METHODS', 'IMRAD_RESULTS', 'IMRAD_DISCUSSION',
  'EPISTEME_SENSORY_PRO',         'TECHNE_SENSORY_PRO',         'PHRONESIS_SENSORY_PRO',
  'EPISTEME_CULINARY_PRO',        'TECHNE_CULINARY_PRO',        'PHRONESIS_CULINARY_PRO',
  'EPISTEME_GASTRONOMY_CULTURE',  'TECHNE_GASTRONOMY_CULTURE',  'PHRONESIS_GASTRONOMY_CULTURE',
  'EPISTEME_HOSPITALITY_MGMT',    'TECHNE_HOSPITALITY_MGMT',    'PHRONESIS_HOSPITALITY_MGMT',
  'EPISTEME_EDUCATOR_RESEARCHER', 'TECHNE_EDUCATOR_RESEARCHER', 'PHRONESIS_EDUCATOR_RESEARCHER',
] as const

// Min-tecken per fält. Efter prompt-revision 2026-07-23 accepterar vi kortare
// svar (30-50 ord ~ 150-250 tecken) när abstract inte stödjer längre påstående
// — ärlig kortfattadhet är bättre än uppdiktad utfyllnad. Utan denna sänkning
// skulle validateTriad avvisa kortare-men-sanna svar som too_short och vi
// skulle byta fabricering mot tomhet.
export const MIN_LEN: Record<string, number> = {
  KNOWLEDGE_EXPLANATION: 30,
  IMRAD_INTRODUCTION: 60, IMRAD_METHODS: 60, IMRAD_RESULTS: 60, IMRAD_DISCUSSION: 60,
  EPISTEME_SENSORY_PRO: 120,          TECHNE_SENSORY_PRO: 120,          PHRONESIS_SENSORY_PRO: 120,
  EPISTEME_CULINARY_PRO: 120,         TECHNE_CULINARY_PRO: 120,         PHRONESIS_CULINARY_PRO: 120,
  EPISTEME_GASTRONOMY_CULTURE: 120,   TECHNE_GASTRONOMY_CULTURE: 120,   PHRONESIS_GASTRONOMY_CULTURE: 120,
  EPISTEME_HOSPITALITY_MGMT: 120,     TECHNE_HOSPITALITY_MGMT: 120,     PHRONESIS_HOSPITALITY_MGMT: 120,
  EPISTEME_EDUCATOR_RESEARCHER: 120,  TECHNE_EDUCATOR_RESEARCHER: 120,  PHRONESIS_EDUCATOR_RESEARCHER: 120,
}

// ─── Prompt-bygge ────────────────────────────────────────────────────────────
export function buildTriadPrompt(article: { title?: string, insight?: string, abstract?: string }): string {
  // Källordning: abstract (originalet) föredras. insight är en Haiku-genererad
  // 1-2 meningars parafras av abstract (daily-fetch rad ~135) — om vi använde
  // insight först skulle vi generera TRIAD från AI-sammanfattning av AI-käll-
  // material, en dubbel-abstraktion som suddar detaljer innan Sonnet ser dem.
  // Fall bara tillbaka till insight om abstract är kort/saknas (edge case:
  // artiklar från Scopus som väntar på backfill-abstracts).
  const source = article.abstract && article.abstract.length >= 200
    ? article.abstract
    : (article.insight || article.abstract || '')

  return `TRIAD: EPISTEME=universal truth 3rd person. TECHNE=craft skill 2nd person. PHRONESIS=situated judgement 2nd person present.
Roles: sensory_pro=Sommelier/sensory scientist, culinary_pro=Chef/fermentation, gastronomy_culture=Food anthropologist/stylist, hospitality_mgmt=F&B manager/hotelier, educator_researcher=Researcher/culinary educator

STRICT RULES (violation = ruined analysis):
1. Ground every claim in the Title+Abstract below. Never invent specifics not present in the source.
2. NEVER fabricate numeric values (pH, temperature, timing, percentage, quantity), ingredient names, place names, or step-by-step procedures. If the source lacks them, do NOT supply them. Write "as reported by the study" or "consult the source for exact values" instead.
3. TECHNE fields may be ARRIVED-AT-GENERALLY when the abstract lacks quantitative protocol. Describe the CLASS of application (what a practitioner should watch for, what dimension the finding informs) — do not fabricate a step-by-step recipe from a study that didn't publish one.
4. If a role cannot be substantively addressed from the abstract, write "The abstract does not provide role-specific application detail; the study's [finding] informs [dimension] but no protocol is derivable" — 30-50 words is acceptable when the source constrains it.
5. Prefer honest generality over confident specificity. A vague-but-true statement outperforms a specific-but-invented one.
6. EPISTEME OPENING: Do not use a repeating template across the 5 Epistemes. Start with the substantive finding itself, not with "The study establishes/finds/demonstrates/reports/identifies" or equivalent report-frame verbs.
7. HEDGING MUST NAME WHAT IS UNCERTAIN. If you write "may", "could", "might", "potentially", or "could indicate", specify in the same sentence WHAT is uncertain — sample size, single-study finding, correlational (not causal) design, restricted context, absence of replication, etc. Example: "may hold in commercial kitchens, though tested only in a lab setting." Vague hedges without stated grounds are noise; either name the source of uncertainty in-line or state the finding plainly.
8. EXPLAIN DOMAIN TERMS THE TARGET ROLE WOULDN'T KNOW. Each role has its own working vocabulary. A sommelier reads "crossmodal correspondences" as jargon; a food anthropologist reads "Rayleigh scattering" the same way; a chef reads "hedonic valence" the same way. When a term from the source study isn't part of the target role's day-to-day language, define it in one clause on first use (parenthetical or by rephrasing entirely in the role's own words). Test: could a working practitioner in this role act on your sentence without a dictionary? If no, rewrite.

Title: "${(article.title || '').slice(0, 200)}"
Abstract: "${source.slice(0, 2000)}"

Write your analysis using EXACTLY these labels, in this exact order. Each label on its own line, followed by the field's text. Do NOT use square brackets in prose. Do NOT omit any label. Close with [END].

[KNOWLEDGE_EXPLANATION]
one-sentence essential summary of the study's central finding

[IMRAD_INTRODUCTION]
research question and context, ~40-60 words

[IMRAD_METHODS]
key methodological features that determine what can be concluded, ~40-60 words

[IMRAD_RESULTS]
the finding as a claim with effect size or direction if reported (do not invent numbers), ~40-60 words

[IMRAD_DISCUSSION]
what the result means and its limits, ~40-60 words

[EPISTEME_SENSORY_PRO]
40-90 words 3rd person analytical, for Sommelier/sensory scientist. Present the finding as a substantive claim relevant to sensory expertise.

[TECHNE_SENSORY_PRO]
40-90 words 2nd person, for Sommelier/sensory scientist. Describe how a sensory professional applies the finding. State only values/protocols that appear in the abstract; otherwise describe the applicable dimension.

[PHRONESIS_SENSORY_PRO]
40-90 words 2nd person present, for Sommelier/sensory scientist. Situated judgment grounded in the abstract, not generic wisdom.

[EPISTEME_CULINARY_PRO]
40-90 words 3rd person analytical, for Chef/fermentation. Present the finding as a substantive claim relevant to culinary work.

[TECHNE_CULINARY_PRO]
40-90 words 2nd person, for Chef/fermentation. Describe how a chef applies the finding. State only values/protocols/ingredients that appear in the abstract; otherwise describe the applicable dimension.

[PHRONESIS_CULINARY_PRO]
40-90 words 2nd person present, for Chef/fermentation. Situated judgment grounded in the abstract.

[EPISTEME_GASTRONOMY_CULTURE]
40-90 words 3rd person analytical, for Food anthropologist/stylist. Present the finding as a substantive claim relevant to cultural or stylistic interpretation.

[TECHNE_GASTRONOMY_CULTURE]
40-90 words 2nd person, for Food anthropologist/stylist. Describe how the finding informs cultural or stylistic practice. State only specifics that appear in the abstract.

[PHRONESIS_GASTRONOMY_CULTURE]
40-90 words 2nd person present, for Food anthropologist/stylist.

[EPISTEME_HOSPITALITY_MGMT]
40-90 words 3rd person analytical, for F&B manager/hotelier. Present the finding as a substantive claim relevant to management or operations.

[TECHNE_HOSPITALITY_MGMT]
40-90 words 2nd person, for F&B manager/hotelier. Describe how the finding informs management or operations. State only specifics that appear in the abstract.

[PHRONESIS_HOSPITALITY_MGMT]
40-90 words 2nd person present, for F&B manager/hotelier.

[EPISTEME_EDUCATOR_RESEARCHER]
40-90 words 3rd person analytical, for Researcher/culinary educator. Present the finding as a substantive claim relevant to teaching or further research.

[TECHNE_EDUCATOR_RESEARCHER]
40-90 words 2nd person, for Researcher/culinary educator. Describe how the finding informs teaching or further research. State only specifics that appear in the abstract.

[PHRONESIS_EDUCATOR_RESEARCHER]
40-90 words 2nd person present, for Researcher/culinary educator.

[END]`
}

// ─── Parser ──────────────────────────────────────────────────────────────────
export type ParseResult = {
  fields: Record<string, string>
  missing: string[]        // labels helt frånvarande
  too_short: Array<{ label: string, len: number, min: number }>   // fanns men för korta
  extra: string[]          // labels Sonnet hittat på (hallucination eller stavfel)
}

export function parseLabeledProse(text: string): ParseResult {
  const expected = new Set<string>(EXPECTED_LABELS)
  const fields: Record<string, string> = {}
  const extra: string[] = []

  // Case-insensitive label-match, måste vara ensamt på en rad.
  const labelRe = /^\[([A-Za-z_]+)\]\s*$/gm
  const matches: Array<{ label: string, start: number, end: number }> = []
  let m: RegExpExecArray | null
  while ((m = labelRe.exec(text)) !== null) {
    matches.push({ label: m[1].toUpperCase(), start: m.index, end: m.index + m[0].length })
  }

  for (let i = 0; i < matches.length; i++) {
    const label = matches[i].label
    if (label === 'END') break   // slutmarkör: allt efter ignoreras
    if (!expected.has(label)) { extra.push(label); continue }
    const contentStart = matches[i].end
    const contentEnd = i + 1 < matches.length ? matches[i + 1].start : text.length
    const value = text.slice(contentStart, contentEnd).trim()
    if (value) fields[label] = value
  }

  const missing = EXPECTED_LABELS.filter(k => !fields[k])
  const too_short = EXPECTED_LABELS
    .filter(k => fields[k] && fields[k].length < MIN_LEN[k])
    .map(k => ({ label: k, len: fields[k].length, min: MIN_LEN[k] }))

  return { fields, missing, too_short, extra }
}

// ─── Validering ──────────────────────────────────────────────────────────────
// Returnerar null om allt OK, annars en sträng som beskriver felen.
// Anropande fn ska INTE skriva till DB om denna returnerar non-null.
export function validateTriad(result: ParseResult): string | null {
  if (result.missing.length === 0 && result.too_short.length === 0) return null
  const parts: string[] = []
  if (result.missing.length)   parts.push(`missing=${result.missing.length}`)
  if (result.too_short.length) parts.push(`too_short=${result.too_short.length}`)
  if (result.extra.length)     parts.push(`extra=${result.extra.length}`)
  return parts.join(', ')
}

// ─── DB-mapping ──────────────────────────────────────────────────────────────
// Bara körs efter validateTriad() returnerat null. Ingen halv-skrivning möjlig.
// knowledge_type='mixed' hårkodad som pipeline gjort tidigare.
// triad_completed_at satt här (en källa till sanning) så pipeline, triad-
// background och triad-on-demand alla stämplar utan att veta om det.
// Migration 20260713110000_articles_triad_completed_at.sql skapar kolumnen.
export function fieldsToDbUpdate(fields: Record<string, string>): Record<string, any> {
  return {
    triad_completed_at:            new Date().toISOString(),
    imrad_introduction:            fields.IMRAD_INTRODUCTION,
    imrad_methods:                 fields.IMRAD_METHODS,
    imrad_results:                 fields.IMRAD_RESULTS,
    imrad_discussion:              fields.IMRAD_DISCUSSION,
    knowledge_explanation:         fields.KNOWLEDGE_EXPLANATION,
    knowledge_type:                'mixed',
    episteme_sensory_pro:          fields.EPISTEME_SENSORY_PRO,
    techne_sensory_pro:            fields.TECHNE_SENSORY_PRO,
    phronesis_sensory_pro:         fields.PHRONESIS_SENSORY_PRO,
    episteme_culinary_pro:         fields.EPISTEME_CULINARY_PRO,
    techne_culinary_pro:           fields.TECHNE_CULINARY_PRO,
    phronesis_culinary_pro:        fields.PHRONESIS_CULINARY_PRO,
    episteme_gastronomy_culture:   fields.EPISTEME_GASTRONOMY_CULTURE,
    techne_gastronomy_culture:     fields.TECHNE_GASTRONOMY_CULTURE,
    phronesis_gastronomy_culture:  fields.PHRONESIS_GASTRONOMY_CULTURE,
    episteme_hospitality_mgmt:     fields.EPISTEME_HOSPITALITY_MGMT,
    techne_hospitality_mgmt:       fields.TECHNE_HOSPITALITY_MGMT,
    phronesis_hospitality_mgmt:    fields.PHRONESIS_HOSPITALITY_MGMT,
    episteme_educator_researcher:  fields.EPISTEME_EDUCATOR_RESEARCHER,
    techne_educator_researcher:    fields.TECHNE_EDUCATOR_RESEARCHER,
    phronesis_educator_researcher: fields.PHRONESIS_EDUCATOR_RESEARCHER,
  }
}
