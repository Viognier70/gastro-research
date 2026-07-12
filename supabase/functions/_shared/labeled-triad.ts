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

// Min-tecken per fält. Sonnet skriver 60-80 ord = ~300-450 tecken för roll-
// fält. Min 180 = ~30 ord (halva målet). IMRaD-fält kortare mål (~40-60 ord).
// Om ett fält är kortare än detta räknas hela analysen som ofullständig.
export const MIN_LEN: Record<string, number> = {
  KNOWLEDGE_EXPLANATION: 30,
  IMRAD_INTRODUCTION: 60, IMRAD_METHODS: 60, IMRAD_RESULTS: 60, IMRAD_DISCUSSION: 60,
  EPISTEME_SENSORY_PRO: 180,          TECHNE_SENSORY_PRO: 180,          PHRONESIS_SENSORY_PRO: 180,
  EPISTEME_CULINARY_PRO: 180,         TECHNE_CULINARY_PRO: 180,         PHRONESIS_CULINARY_PRO: 180,
  EPISTEME_GASTRONOMY_CULTURE: 180,   TECHNE_GASTRONOMY_CULTURE: 180,   PHRONESIS_GASTRONOMY_CULTURE: 180,
  EPISTEME_HOSPITALITY_MGMT: 180,     TECHNE_HOSPITALITY_MGMT: 180,     PHRONESIS_HOSPITALITY_MGMT: 180,
  EPISTEME_EDUCATOR_RESEARCHER: 180,  TECHNE_EDUCATOR_RESEARCHER: 180,  PHRONESIS_EDUCATOR_RESEARCHER: 180,
}

// ─── Prompt-bygge ────────────────────────────────────────────────────────────
export function buildTriadPrompt(article: { title?: string, insight?: string, abstract?: string }): string {
  return `TRIAD: EPISTEME=universal truth 3rd person. TECHNE=craft skill 2nd person instructional. PHRONESIS=situated judgement 2nd person present.
Roles: sensory_pro=Sommelier/sensory scientist, culinary_pro=Chef/fermentation, gastronomy_culture=Food anthropologist/stylist, hospitality_mgmt=F&B manager/hotelier, educator_researcher=Researcher/culinary educator
Title: "${(article.title || '').slice(0, 150)}"
Finding: "${(article.insight || article.abstract || '').slice(0, 300)}"

Write your analysis using EXACTLY these labels, in this exact order. Each label on its own line, followed by the field's text. Do NOT use square brackets in prose. Do NOT omit any label. Close with [END].

[KNOWLEDGE_EXPLANATION]
one-sentence essential summary of what this study establishes

[IMRAD_INTRODUCTION]
research question and context, ~40-60 words

[IMRAD_METHODS]
key methodological features that determine what can be concluded, ~40-60 words

[IMRAD_RESULTS]
the finding as a claim with effect size or direction, ~40-60 words

[IMRAD_DISCUSSION]
what the result means and its limits, ~40-60 words

[EPISTEME_SENSORY_PRO]
60-80 words 3rd person analytical, for Sommelier/sensory scientist

[TECHNE_SENSORY_PRO]
60-80 words 2nd person instructional, for Sommelier/sensory scientist

[PHRONESIS_SENSORY_PRO]
60-80 words 2nd person present vivid, for Sommelier/sensory scientist

[EPISTEME_CULINARY_PRO]
60-80 words 3rd person analytical, for Chef/fermentation

[TECHNE_CULINARY_PRO]
60-80 words 2nd person instructional, for Chef/fermentation

[PHRONESIS_CULINARY_PRO]
60-80 words 2nd person present vivid, for Chef/fermentation

[EPISTEME_GASTRONOMY_CULTURE]
60-80 words 3rd person analytical, for Food anthropologist/stylist

[TECHNE_GASTRONOMY_CULTURE]
60-80 words 2nd person instructional, for Food anthropologist/stylist

[PHRONESIS_GASTRONOMY_CULTURE]
60-80 words 2nd person present vivid, for Food anthropologist/stylist

[EPISTEME_HOSPITALITY_MGMT]
60-80 words 3rd person analytical, for F&B manager/hotelier

[TECHNE_HOSPITALITY_MGMT]
60-80 words 2nd person instructional, for F&B manager/hotelier

[PHRONESIS_HOSPITALITY_MGMT]
60-80 words 2nd person present vivid, for F&B manager/hotelier

[EPISTEME_EDUCATOR_RESEARCHER]
60-80 words 3rd person analytical, for Researcher/culinary educator

[TECHNE_EDUCATOR_RESEARCHER]
60-80 words 2nd person instructional, for Researcher/culinary educator

[PHRONESIS_EDUCATOR_RESEARCHER]
60-80 words 2nd person present vivid, for Researcher/culinary educator

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
export function fieldsToDbUpdate(fields: Record<string, string>): Record<string, any> {
  return {
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
