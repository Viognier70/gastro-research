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
  // uppfyllt av varje artikel.
  // 2026-08-24 (ORDER 149 v-d): label → 'Academic' och rubrik omskriven
  // från FILTER till PLACERINGS-fråga (rollen är sortnyckel, inte filter).
  // Iterativt kalibrerad över fyra sample-körningar; slutform verifierad
  // med 100-sample-sample: 9-10-band = 3 rader (metod-som-ämne + pedagogy),
  // klump på 7 = 48/100. Denna prompt matchar batch-regen-sci.ts v2026-08-24d.
  { role_key: 'educator_researcher', role_label: 'Academic' },
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

The daily-application test above does not apply to educator_researcher. For this role, relevance is measured by transferability across specializations, per the rubric below.

For educator_researcher (the Academic role):

Academic — researchers and educators in gastronomy. This role is defined by breadth of curiosity, not by subject boundary. Specializations vary widely (fermentation science, food policy, sensory analysis, culinary pedagogy), so the corpus is never filtered — only ordered.

Rank by transferability across specializations, not by topical fit.

9-10 — Portable across the whole role. Articles about how gastronomic knowledge is taught, trained, and transmitted (pedagogy, didactics, curriculum, skills transfer), and articles *about* research methods or data collection — new instruments, protocols, sampling approaches, panel design, measurement validity. Useful to every academic regardless of specialization.

8 — Strong within a specialization, with reach beyond it. Findings, techniques, or framings a researcher in an adjacent gastronomic field could act on.

7 — Solid within a specialization, self-contained. Valuable to those already in that field.

6 — Narrow or incremental within a specialization. Small effect, replication, or a single-context result.

5 — Relevant background. Industry, policy, production, or cultural coverage an academic would read for context.

3-4 — Peripheral but present. Consumer, trade, or lifestyle coverage with thin analytical content.

1-2 — Barely touches gastronomy.

0 — Not gastronomy at all.

CRITICAL DISTINCTION: an article that *uses* a method is not an article *about* a method. Standard research reporting with a methods section belongs at 6-8. Reserve 9-10 for work whose subject is the method itself.

Titles of the form "X using Y" describe a study of X with Y as the instrument — score these on X, typically 7-8. Score 9-10 when the article's own contribution is the method, the instrument, or the teaching of the field: introducing, validating, comparing, or reviewing methods, or any work on pedagogy, curriculum, or skills transfer.

Nothing is excluded. Every article receives a placement. If unsure between two scores, choose the higher — this role reads widely by disposition.

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
