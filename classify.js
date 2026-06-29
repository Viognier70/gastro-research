// TRIAD Article Classification Pipeline
// Run this in Node.js locally or as a Supabase Edge Function
// Classifies each article as ε/τ/φ dominant with confidence score
//
// Prerequisites:
// npm install @supabase/supabase-js @anthropic-ai/sdk
//
// Usage: node classify.js

import Anthropic from '@anthropic-ai/sdk'
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY // service key — not anon
)

const anthropic = new Anthropic({
  apiKey: process.env.ANTHROPIC_API_KEY
})

// ── CLASSIFICATION PROMPT ──────────────────────────────────────────
const CLASSIFY_PROMPT = (abstract, insight = '', application = '', studyType = '') => `
You are classifying a peer-reviewed gastronomy research article 
by its PRIMARY epistemological orientation according to Aristotle's 
three forms of knowledge as defined by Crichton-Fock (2024).

DEFINITIONS:
- episteme: Article primarily DESCRIBES, MEASURES, or PROVES a 
  phenomenon. Empirical studies, theoretical contributions, 
  systematic reviews, meta-analyses. The article advances 
  declarative knowledge about what is true.

- techne: Article primarily DEVELOPS, TESTS, or VALIDATES a method, 
  protocol, or craft practice. Training studies, QDA development, 
  protocol standardisation, skill acquisition research. The article 
  advances procedural knowledge about how to do something.

- phronesis: Article primarily addresses PROFESSIONAL JUDGMENT, 
  ETHICS, AESTHETICS, or SITUATED EXPERTISE. Phenomenological 
  studies, expertise research, ethical frameworks, aesthetic theory. 
  The article advances wisdom about when and why to act.

ABSTRACT:
${abstract || 'Not available'}

${insight ? `EPISTEME ANALYSIS (what the research establishes):\n${insight}\n` : ''}
${application ? `TECHNE ANALYSIS (practical application):\n${application}\n` : ''}
${studyType ? `STUDY TYPE: ${studyType}\n` : ''}

Respond with ONLY valid JSON — no preamble, no markdown:
{
  "orientation": "episteme" | "techne" | "phronesis",
  "confidence": 0.0–1.0,
  "rationale": "one sentence explaining the classification",
  "mixed": true | false
}

If the article clearly spans two orientations, set mixed: true 
and choose the more dominant one.
If confidence is below 0.65, set mixed: true regardless.
`

// ── CLASSIFY ONE ARTICLE ───────────────────────────────────────────
async function classifyArticle(article) {
  try {
    const msg = await anthropic.messages.create({
      model: 'claude-haiku-4-5-20251001',
      max_tokens: 200,
      messages: [{
        role: 'user',
        content: CLASSIFY_PROMPT(
          article.abstract || article.title || '',
          article.methods_keywords || ''
        )
      }]
    })

    const raw = msg.content[0].text.trim()
    const cleaned = raw.replace(/^```json\s*/,'').replace(/```\s*$/,'').trim()
const result = JSON.parse(cleaned)

    return {
      triad_orientation: result.orientation,
      triad_orientation_confidence: result.confidence,
      triad_orientation_rationale: result.rationale,
      triad_orientation_mixed: result.mixed,
      triad_orientation_at: new Date().toISOString()
    }
  } catch (err) {
    console.error(`  ✗ Failed for article ${article.id}:`, err.message)
    return null
  }
}

// ── MAIN PIPELINE ──────────────────────────────────────────────────
async function runClassification() {
  console.log('── Gusto Science TRIAD Classification Pipeline ──\n')

  // Fetch unclassified articles (add WHERE clause to resume)
  const { data: articles, error } = await supabase
    .from('articles')
    .select('id, title, abstract, insight, application, study_type')
    .is('triad_orientation', null)   // only unclassified
    .order('fetched_at', { ascending: true })
    .limit(500)                       // process in batches of 500

  if (error) { console.error('Supabase fetch error:', error); return }
  if (!articles.length) { console.log('No unclassified articles found.'); return }

  console.log(`Found ${articles.length} articles to classify.\n`)

  let counts = { episteme: 0, techne: 0, phronesis: 0, failed: 0 }
  let processed = 0

  for (const article of articles) {
    process.stdout.write(`[${++processed}/${articles.length}] ${article.title?.slice(0,60)}... `)

    const classification = await classifyArticle(article)

    if (!classification) {
      counts.failed++
      process.stdout.write('FAILED\n')
      continue
    }

    // Write to Supabase
    const { error: updateError } = await supabase
      .from('articles')
      .update(classification)
      .eq('id', article.id)

    if (updateError) {
      console.error('\n  Supabase update error:', updateError.message)
      counts.failed++
    } else {
      counts[classification.triad_orientation]++
      process.stdout.write(
        `${classification.triad_orientation} (${Math.round(classification.triad_orientation_confidence * 100)}%)\n`
      )
    }

    // Rate limit: ~40 req/min for Haiku
    await new Promise(r => setTimeout(r, 1600))
  }

  // Summary
  const total = articles.length - counts.failed
  console.log('\n── Classification complete ──')
  console.log(`ε Episteme:   ${counts.episteme} (${pct(counts.episteme, total)}%)`)
  console.log(`τ Techne:     ${counts.techne} (${pct(counts.techne, total)}%)`)
  console.log(`φ Phronesis:  ${counts.phronesis} (${pct(counts.phronesis, total)}%)`)
  console.log(`Failed:       ${counts.failed}`)
  console.log(`\nUpdate foundation.html with these percentages.`)
}

const pct = (n, total) => total ? Math.round(n / total * 100) : 0
runClassification()