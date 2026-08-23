// Delad Haiku sci-analyser (relevansbedömning + keywords + core_claim +
// headline + study_type). Läser abstract med gastro-kontext-prompt och
// returnerar strukturerad JSON.
//
// Enda källa till runSci-logiken. Importeras av:
//   - pipeline/index.ts (kör vid batch-processing efter claim_pipeline_batch)
//   - backfill-haiku-sci/index.ts (kör vid Del 3-svepet av no-role-populationen)
//   - sanity-haiku-sample/index.ts (kör vid diagnos-testning)
//
// Extraherad 2026-07-18 från pipeline/index.ts:22-62. Prompt + parsning
// oförändrad — förändringar HÄR träffar alla tre call sites vid nästa
// deploy. Anthropic-nyckeln passas in som PARAMETER (inte modul-global)
// för att göra funktionen explicit och testbar.

export const ROLES = [
  { role_key: 'sensory_pro',         role_label: 'Sommelier' },
  { role_key: 'culinary_pro',        role_label: 'Chef' },
  { role_key: 'gastronomy_culture',  role_label: 'Gastronomy' },
  { role_key: 'hospitality_mgmt',    role_label: 'F&B Manager' },
  // 2026-08-23: label omskriven från 'Food Researcher & Educator' till
  // operationellt scope. Bakgrund: analys visade kluster 7.03-8.78 (snitt
  // ~8) över alla 27 topics för denna roll — Haiku tolkade "researcher's
  // core task" som "läsa peer-reviewed forskning", vilket är trivialt
  // uppfyllt av varje artikel. Nya label:n + role-specifika rubrik-clause
  // nedan (rad ~64) fokuserar scoringen på pedagogik/metod/study-design
  // istället för läsvärdhet.
  { role_key: 'educator_researcher', role_label: 'Educator/researcher — method & pedagogy in gastronomy' },
] as const

export interface SciRoleScores {
  sensory_pro?: number
  culinary_pro?: number
  gastronomy_culture?: number
  hospitality_mgmt?: number
  educator_researcher?: number
}

export interface SciResult {
  role_scores?: SciRoleScores
  keywords?: string[]
  core_claim?: string | null
  headline_en?: string | null
  study_type?: string | null
}

export interface ArticleForSci {
  title?: string
  abstract?: string
  journal?: string
}

// Kör Haiku 4.5 mot artikelns title + abstract + journal med gastro-kontext-
// prompt. Returnerar null vid Haiku-fel, parse-error eller exception.
// Prompten är EXAKT som originalet (pipeline/index.ts före extraktion) —
// ändringar spårar tillbaka hit.
export async function runSci(article: ArticleForSci, anthropicKey: string): Promise<SciResult | null> {
  try {
    const roleList = ROLES.map(r => `"${r.role_key}":"${r.role_label}"`).join(',')
    const prompt = `Analyze for Gusto Science (culinary/hospitality platform).
Title: "${(article.title || '').slice(0, 200)}"
Abstract: "${(article.abstract || '').slice(0, 400)}"
Journal: "${article.journal || ''}"
Score relevance 0-10. BE STRICT: only high if professional can directly apply in daily work.
8-10: directly addresses core tasks. 5-7: clear indirect application. 1-4: marginal. 0: irrelevant.

For educator_researcher, high scores (8-10) apply ONLY to studies about HOW gastronomy is taught, learned, or investigated — pedagogy, curriculum, research method, study design. Do NOT score high just because a researcher would find the paper interesting to read; reading peer-reviewed literature is not by itself a scoring criterion.

Roles: {${roleList}}
Return ONLY JSON: {"role_scores":{"sensory_pro":0,"culinary_pro":0,"gastronomy_culture":0,"hospitality_mgmt":0,"educator_researcher":0},"keywords":["k1","k2"],"core_claim":"one precise factual finding","headline_en":"max 8 words no punctuation","study_type":"experimental|observational|review|meta-analysis|qualitative"}`

    const resp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': anthropicKey,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 500,
        messages: [{ role: 'user', content: prompt }],
      }),
    })
    if (!resp.ok) {
      // .catch(()=>{}) — arrow med function body {}, returnerar undefined.
      // JSON.stringify(undefined) = undefined literal → loggas som
      // "undefined" i pipelinen. Bevaras för bit-för-bit-identitet.
      const err = await resp.json().catch(() => {})
      console.log('Haiku error:', resp.status, JSON.stringify(err))
      return null
    }
    const d = await resp.json()
    let t = (d.content?.[0]?.text || '{}').trim()
    t = t.replace(/^```json\s*/, '').replace(/^```\s*/, '').replace(/```[\s\S]*$/, '').trim()
    return JSON.parse(t)
  } catch (e: any) {
    console.log('runSci error:', e.message)
    return null
  }
}
