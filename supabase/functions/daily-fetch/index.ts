import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SB_URL = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SERVICE_ROLE_KEY') || ''
const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') || ''

const BLOCKED_JOURNALS = new Set([
  'environment development and sustainability','discover psychology',
  'educational psychology review','consciousness and cognition',
  'discover sustainability','acta psychologica','ai and society',
  'attention perception and psychophysics','animals','agronomy',
  'bmj open quality','brain research','brain research bulletin',
  'cancer cell international','cell and bioscience','cell death discovery',
  'cell reports','cells','behavioural brain research','experimental brain research',
  'heliyon','plos one','scientific reports',
  'international journal of environmental research and public health',
  'frontiers in public health','medicine','journal of clinical medicine',
  'biomedicines','pharmaceuticals','cancers','microorganisms',
  'acta psychologica sinica','bmc public health',
  'american journal of clinical nutrition','current opinion in food science',
  'dictionary of ecological economics terms for the new millennium',
  'encyclopedia of tourism management and marketing volume 1 4',
])

const FOOD_KEYWORDS = /wine|sommelier|tasting|flavor|flavour|aroma|taste|sensory|crossmodal|multisensory|gastronom|culinar|pairing|olfact|umami|ferment|beverage|hospitality|restaurant|chef|cuisine|eating|food quality|food science|food technol/i

// Trusted core gastronomy/food-science journals — always allowed through the relevance gate
const TRUSTED_JOURNALS = /food quality and preference|appetite|chemical senses|international journal of gastronomy|journal of sensory studies|food research international|flavour|journal of culinary|food science|food technolog|meat science|journal of wine|oeno|beverages|fermentation|food chemistry|nutrients|critical reviews in food/i

function isBlockedJournal(journal: string, title: string, abstract: string): boolean {
  if(!journal) return false
  const j = journal.toLowerCase().trim()
  if(BLOCKED_JOURNALS.has(j)) return true
  // Breda journaler kräver mat/gastronomi-sökord
  const BROAD = ['frontiers in psychology','frontiers in neuroscience','sustainability','molecules','nutrients','antioxidants','foods']
  if(BROAD.includes(j) && !FOOD_KEYWORDS.test(title + ' ' + (abstract||''))) return true
  return false
}
const SCOPUS_KEY = '394f43f3b56c0271865da601cbe7e786'
// Scopus indexeras praktiskt från tidigt 1970-tal, PubMed från 1966. Under
// 1970 finns i vår domän i princip inget (Chemical Senses börjar 1974,
// Journal of Texture Studies 1969, moderna sensory-vetenskapen är i mångt
// en 1980-tals-företeelse). 1970 är gränsen där tomma ticks tar över — vi
// behöver inte ticka längre. completed = true sätts när svepet decrementat
// nedanför denna floor och faller ur runBackfills pool.
const MIN_YEAR = 1970

const supabase = createClient(SB_URL, SB_SERVICE_KEY)

// ─── TOPIC DETECTION ──────────────────────────────────────────────────────────
const TOPICS: Record<string, string[]> = {
  sommellerie: ['sommelier', 'wine tasting', 'wine evaluation', 'oenology', 'wine sensory', 'viticulture'],
  gastronomy: ['gastronomy', 'haute cuisine', 'culinary arts', 'fine dining', 'gourmet'],
  multisensory: ['multisensory', 'crossmodal', 'sensory integration', 'multimodal'],
  culinary_science: ['culinary science', 'cooking science', 'culinary chemistry'],
  food_science: ['food science', 'food technology', 'food processing'],
  flavor_science: ['food flavor', 'food flavour', 'taste perception food', 'olfaction food', 'food aroma', 'retronasal olfaction'],
  sensory_evaluation: ['sensory evaluation', 'sensory panel', 'sensory analysis'],
  food_psychology: ['food psychology', 'eating behavior', 'food choice', 'food preference'],
  neurogastronomy: ['neurogastronomy', 'neuroculinary', 'brain taste', 'flavor neuroscience'],
  food_anthropology: ['food anthropology', 'food culture', 'food identity', 'culinary tradition'],
  atmospherics: ['atmospherics', 'ambient', 'restaurant environment', 'dining atmosphere'],
  hospitality: ['hospitality', 'service quality', 'guest experience', 'hotel management'],
  servicescape: ['servicescape', 'physical environment service'],
  experiential_dining: ['experiential dining', 'immersive dining', 'themed restaurant'],
  nutritional_science: ['nutritional science', 'nutrition', 'dietary', 'macronutrient'],
  food_behavior: ['food behavior', 'eating habits', 'dietary behavior', 'food intake'],
  appetite_research: ['appetite', 'hunger', 'satiety', 'satiation', 'food reward'],
  food_technology: ['food technology', 'food innovation', 'novel processing'],
  fermentation_science: ['fermentation', 'fermented food', 'probiotic', 'koji'],
  food_pairing: ['food pairing', 'flavor pairing', 'wine pairing'],
  molecular_mixology: ['molecular mixology', 'molecular gastronomy', 'spherification'],
  culinary_education: ['culinary education', 'chef training', 'culinary school'],
  sensory_training: ['sensory training', 'taste training', 'olfactory training'],
  novel_foods: ['novel foods', 'insect protein', 'lab-grown meat', 'plant-based meat'],
  crossmodal: ['crossmodal', 'cross-modal', 'sound taste', 'music food', 'color taste'],
  art_science: ['food design', 'plating aesthetics', 'food aesthetics', 'culinary art'],
}

function detectTopic(title: string, abstract: string, journal: string): string {
  const text = `${title} ${abstract} ${journal}`.toLowerCase()
  let bestTopic = 'gastronomy'
  let bestScore = 0
  for (const [topic, keywords] of Object.entries(TOPICS)) {
    const score = keywords.filter(k => text.includes(k.toLowerCase())).length
    if (score > bestScore) { bestScore = score; bestTopic = topic }
  }
  return bestTopic
}

// ─── RELEVANCE GATE ───────────────────────────────────────────────────────────
// Returns a reason string if the article should be REJECTED, or null if it passes.
// Applies to ALL sources (Scopus, OpenAlex, PubMed, researchers, fresh).
function relevanceReject(article: any): string | null {
  // B1: abstract is NOT required at collection time — Scopus search API does not
  // return abstracts; they are filled in later by the backfill-abstracts job.
  // The real abstract-based relevance judgement happens in the separate
  // relevance-check step (B2), after enrichment. Here we only do a COARSE filter.
  // 1. Must have a DOI (scientific traceability — available from search results)
  if (!article.doi && !/doi/i.test(article.url || '')) return 'no DOI'
  // 2. Coarse relevance on title + journal (abstract usually absent at this stage):
  //    trusted core journal OR food keywords in the title.
  const j = (article.journal || '').toLowerCase()
  const txt = `${article.title} ${article.abstract || ''}`
  if (!TRUSTED_JOURNALS.test(j) && !FOOD_KEYWORDS.test(txt)) return 'off-topic'
  // 3. Explicit journal blocklist still applies
  if (isBlockedJournal(article.journal || '', article.title || '', article.abstract || '')) return 'blocked journal'
  return null
}

// ─── GEMINI ANALYSIS ──────────────────────────────────────────────────────────
async function analyzeWithClaude(title: string, abstract: string, topic: string): Promise<any> {
  const prompt = `You are a research analyst for gastronomy and food science. Return ONLY valid JSON (no markdown):

Title: "${title.slice(0, 150)}"
Topic: ${topic.replace(/_/g, ' ')}
Abstract: "${abstract.slice(0, 400)}"

{"insight":"1-2 sentences key finding for culinary professionals","application":"1 sentence how to apply","limitation":"1 sentence main limitation","limit_type":"sample_size|methodology|context|generalizability|other","study_type":"experimental|observational|review|meta-analysis|case-study|other"}`

  try {
    const resp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': ANTHROPIC_KEY,
        'anthropic-version': '2023-06-01'
      },
      body: JSON.stringify({
        model: 'claude-sonnet-4-5',
        max_tokens: 500,
        messages: [{ role: 'user', content: prompt }]
      })
    })
    const d = await resp.json()
    const txt = (d.content?.[0]?.text || '{}').replace(/```json|```/g, '').trim()
    return JSON.parse(txt)
  } catch(e) { return {} }
}

// ─── DUPLICATE CHECK ──────────────────────────────────────────────────────────
async function isDuplicate(doi: string, title: string): Promise<boolean> {
  if (doi) {
    const { data } = await supabase.from('articles').select('id')
      .or(`url.eq.https://doi.org/${doi},url.ilike.%${doi}%`).limit(1)
    if (data?.length) return true
  }
  const { data } = await supabase.from('articles').select('id')
    .ilike('title', title.slice(0, 80).replace(/[%_]/g, ' ')).limit(1)
  return !!(data?.length)
}

// ─── SAVE ARTICLE ─────────────────────────────────────────────────────────────
async function saveArticle(article: any, topic: string): Promise<boolean> {
  try {
    if (!article.title || article.title.length < 10) return false

    // ── RELEVANSGRIND (gäller ALLA källor) ──
    const reject = relevanceReject(article)
    if (reject) {
      console.log(`Skipped (${reject}): ${article.title.slice(0,60)} [${article.journal || '-'}]`)
      return false
    }

    if (await isDuplicate(article.doi || '', article.title)) return false

    const analysis = article.abstract?.length > 50 ?
      await analyzeWithClaude(article.title, article.abstract, topic) : {}

    const { error } = await supabase.from('articles').insert({
      title: article.title,
      authors: article.authors || '',
      journal: article.journal || '',
      year: article.year || null,
      topic,
      source: article.source,
      source_label: article.source_label,
      url: article.url || '',
      abstract: article.abstract || '',
      insight: analysis.insight || '',
      application: analysis.application || '',
      limitation: analysis.limitation || '',
      limit_type: analysis.limit_type || '',
      study_type: analysis.study_type || '',
      // Institution linkage from source APIs. Preserves the
      // affiliation-text that used to get discarded — makes the map
      // institution-vy queryable per institution (see migration
      // 20260707120000_affiliations_column.sql).
      institutions: article.institutions?.length ? article.institutions : null,
      institution_coords: article.institution_coords?.length ? article.institution_coords : null,
      affiliations: article.affiliations?.length ? article.affiliations : null,
      primary_institution: article.primary_institution || null,
      country: article.country || null,
      countries: article.countries?.length ? article.countries : null,
      fetched_at: new Date().toISOString()
    })
    if (error) console.log('Save error:', error.message)
    return !error
  } catch(e: any) {
    console.log('saveArticle error:', e.message)
    return false
  }
}

// ─── SCOPUS ENTRY MAPPER ─────────────────────────────────────────────────────
// Both fetchScopusPage (journal-scoped) and fetchResearchers (AU-ID-scoped)
// call the same Search API endpoint with STANDARD view — response shape is
// identical, so both go through this mapper. Keeps the affilname/-city/
// -country extraction in one place instead of drifting into two copies.
// yearFallback: use 0 in journal-fetch (matches previous no-date → 0
// behaviour); use the search year in researcher-fetch so an entry without
// prism:coverDate at least stays inside the requested year window.
function mapScopusEntry(e: any, defaultJournal: string, yearFallback: number): any {
  const authorList = e['authors']?.author || []
  const authors = authorList.map((a: any) =>
    `${a['given-name'] || ''} ${a['surname'] || ''}`.trim()
  ).filter(Boolean).join(', ') || e['dc:creator'] || ''
  const doi = e['prism:doi'] || ''
  const affilsRaw = e['affiliation'] || []
  const affilArr = Array.isArray(affilsRaw) ? affilsRaw : [affilsRaw]

  // Rich affiliation text: name + city + country when Scopus provides
  // them. Preserves the department/campus signal that got thrown away.
  const affiliations = affilArr
    .map((a: any) => {
      const name = (a['affilname'] || '').trim()
      const city = (a['affiliation-city'] || '').trim()
      const country = (a['affiliation-country'] || '').trim()
      return [name, city, country].filter(Boolean).join(', ')
    })
    .filter(Boolean)
  const institutions = [...new Set(
    affilArr.map((a: any) => (a['affilname'] || '').trim()).filter(Boolean)
  )] as string[]
  const countries = [...new Set(
    affilArr.map((a: any) => a['affiliation-country'] || a?.['@country'] || '').filter(Boolean)
  )] as string[]
  const country = countries[0] || ''

  return {
    title: e['dc:title'] || '',
    abstract: e['dc:description'] || '',
    authors,
    journal: e['prism:publicationName'] || defaultJournal,
    year: parseInt(e['prism:coverDate']?.slice(0, 4) || '0') || yearFallback,
    country,
    countries: countries.length ? countries : null,
    institutions,
    affiliations,
    primary_institution: institutions[0] || null,
    doi,
    url: doi ? `https://doi.org/${doi}` : (e['prism:url'] || ''),
    source: 'scopus', source_label: 'Scopus'
  }
}

// ─── SCOPUS FETCH (with pagination) ──────────────────────────────────────────
async function fetchScopusPage(journal: string, year: number, page: number): Promise<{articles: any[], hasMore: boolean}> {
  const start = page * 25
  try {
    const query = encodeURIComponent(`SRCTITLE("${journal}") AND PUBYEAR IS ${year}`)
    const url = `https://api.elsevier.com/content/search/scopus?query=${query}&count=25&start=${start}&sort=-coverDate&apiKey=${SCOPUS_KEY}&httpAccept=application%2Fjson`

    const r = await fetch(url)
    if (!r.ok) {
      console.log(`Scopus ${journal} ${year} p${page}: HTTP ${r.status}`)
      return { articles: [], hasMore: false }
    }
    const d = await r.json()
    const entries = d['search-results']?.entry || []
    const total = parseInt(d['search-results']?.['opensearch:totalResults'] || '0')
    const hasMore = (start + 25) < total && total > 0

    const articles = entries
      .map((e: any) => mapScopusEntry(e, journal, 0))
      .filter((a: any) => a.title.length > 5)

    console.log(`Scopus ${journal} ${year} p${page}: ${entries.length}/${total}`)
    return { articles, hasMore }
  } catch(e: any) {
    console.log(`Scopus error ${journal}:`, e.message)
    return { articles: [], hasMore: false }
  }
}

// ─── PUBMED FETCH (with year + pagination) ────────────────────────────────────
async function fetchPubMedPage(query: string, year: number, page: number): Promise<{articles: any[], hasMore: boolean}> {
  try {
    const retmax = 20
    const retstart = page * retmax
    const fullQuery = `(${query}[Title/Abstract]) AND (${year}[PDAT])`
    const searchUrl = `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=${encodeURIComponent(fullQuery)}&retmax=${retmax}&retstart=${retstart}&sort=date&retmode=json`
    const searchR = await fetch(searchUrl)
    const searchD = await searchR.json()
    const ids = searchD.esearchresult?.idlist || []
    const total = parseInt(searchD.esearchresult?.count || '0')
    const hasMore = (retstart + retmax) < total

    if (!ids.length) return { articles: [], hasMore: false }

    const fetchUrl = `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed&id=${ids.join(',')}&retmode=xml`
    const fetchR = await fetch(fetchUrl)
    const xml = await fetchR.text()
    const articleMatches = xml.match(/<PubmedArticle>[\s\S]*?<\/PubmedArticle>/g) || []

    const articles = articleMatches.map(articleXml => {
      const title = articleXml.match(/<ArticleTitle>([\s\S]*?)<\/ArticleTitle>/)?.[1]?.replace(/<[^>]+>/g, '') || ''
      const abstract = articleXml.match(/<AbstractText[^>]*>([\s\S]*?)<\/AbstractText>/)?.[1]?.replace(/<[^>]+>/g, '') || ''
      const journal = articleXml.match(/<Title>([\s\S]*?)<\/Title>/)?.[1] || ''
      const doi = articleXml.match(/<ELocationID EIdType="doi"[^>]*>([\s\S]*?)<\/ELocationID>/)?.[1] || ''
      const authorMatches = articleXml.match(/<Author[^>]*>[\s\S]*?<\/Author>/g) || []
      const authors = authorMatches.map(a => {
        const last = a.match(/<LastName>(.*?)<\/LastName>/)?.[1] || ''
        const fore = a.match(/<ForeName>(.*?)<\/ForeName>/)?.[1] || ''
        return `${fore} ${last}`.trim()
      }).filter(Boolean).join(', ')
      // PubMed <Affiliation> is per-author, often duplicated across
      // authors from the same lab. Dedupe. Institution = the first
      // comma-separated segment ("Örebro University, School of ..." →
      // "Örebro University"). Heuristic; good enough for filtering.
      const affiliations = [...new Set(
        (articleXml.match(/<Affiliation>[\s\S]*?<\/Affiliation>/g) || [])
          .map(m => m.replace(/<\/?Affiliation>/g, '').replace(/<[^>]+>/g, '').trim())
          .filter(Boolean)
      )] as string[]
      const institutions = [...new Set(
        affiliations.map(a => a.split(',')[0].trim()).filter(Boolean)
      )] as string[]
      return { title, abstract, authors, journal, year, doi,
        url: doi ? `https://doi.org/${doi}` : '',
        institutions,
        affiliations,
        primary_institution: institutions[0] || null,
        source: 'pubmed', source_label: 'PubMed' }
    }).filter(a => a.title.length > 5)

    console.log(`PubMed ${query} ${year} p${page}: ${articles.length}/${total}`)
    return { articles, hasMore }
  } catch(e: any) {
    console.log('PubMed error:', e.message)
    return { articles: [], hasMore: false }
  }
}

// ─── OPENALEX FETCH (with year + pagination) ──────────────────────────────────
async function fetchOpenAlexPage(query: string, year: number, page: number): Promise<{articles: any[], hasMore: boolean}> {
  try {
    const perPage = 20
    const url = `https://api.openalex.org/works?search=${encodeURIComponent(query)}&per-page=${perPage}&page=${page + 1}&filter=type:article,publication_year:${year}&sort=cited_by_count:desc`
    const r = await fetch(url, { headers: { 'User-Agent': 'GustoScience/1.0 (gusto.science)' } })
    if (!r.ok) return { articles: [], hasMore: false }
    const d = await r.json()
    const total = d.meta?.count || 0
    const hasMore = ((page + 1) * perPage) < total

    const articles = (d.results || []).map((w: any) => {
      const authorships = w.authorships || []
      const flatInsts = authorships.flatMap((a: any) => a.institutions || [])
      const institutions = [...new Set(flatInsts.map((i: any) => i.display_name).filter(Boolean))] as string[]
      const institution_coords = flatInsts
        .filter((i: any) => i.geo?.latitude)
        .map((i: any) => ({ name: i.display_name, lat: i.geo.latitude, lng: i.geo.longitude, country: i.country_code }))
        .filter((v: any, i: number, a: any[]) => a.findIndex((x: any) => x.name === v.name) === i)
      const countries = [...new Set(flatInsts.map((i: any) => i.country_code).filter(Boolean))] as string[]
      // raw_affiliation_strings preserves department/campus text ("Örebro
      // University, Grythyttan Campus") that display_name flattens away.
      const affiliations = [...new Set(
        authorships.flatMap((a: any) => a.raw_affiliation_strings || []).filter(Boolean)
      )] as string[]
      return {
        title: w.title || '',
        abstract: w.abstract || '',
        journal: w.primary_location?.source?.display_name || '',
        year: w.publication_year || year,
        doi: w.doi?.replace('https://doi.org/', '') || '',
        url: w.doi || w.id || '',
        authors: authorships.map((a: any) => a.author?.display_name || '').filter(Boolean).join(', '),
        country: countries[0] || '',
        institutions,
        institution_coords,
        countries,
        affiliations,
        primary_institution: institutions[0] || null,
        source: 'openalex', source_label: 'OpenAlex'
      }
    }).filter((a: any) => a.title.length > 5 && !isBlockedJournal(a.journal||'', a.title||'', a.abstract||''))

    console.log(`OpenAlex ${query} ${year} p${page}: ${articles.length}/${total}`)
    return { articles, hasMore }
  } catch(e: any) {
    console.log('OpenAlex error:', e.message)
    return { articles: [], hasMore: false }
  }
}

// ─── SEMANTIC SCHOLAR FETCH ───────────────────────────────────────────────────
const ARXIV_BLOCKED_PREFIXES = ['cs.LG','cs.CV','cs.AI','cs.NE','cs.CL','cs.IR','cs.RO','stat.ML','math.','eess.','cs.HC','cs.MM']

function isBlockedArxiv(externalIds: any): boolean {
  const arxivId = externalIds?.ArXiv
  if(!arxivId) return false
  return false // Categories not available; use Haiku relevance scoring instead
}

async function fetchSemanticScholar(query: string, year: number): Promise<any[]> {
  try {
    const url = `https://api.semanticscholar.org/graph/v1/paper/search?query=${encodeURIComponent(query)}&limit=10&fields=title,abstract,authors,year,externalIds,venue&year=${year}`
    const r = await fetch(url, { headers: { 'User-Agent': 'GustoScience/1.0' } })
    if (!r.ok) return []
    const d = await r.json()
    return (d.data || []).map((p: any) => ({
      title: p.title || '',
      abstract: p.abstract || '',
      journal: p.venue || '',
      year: p.year || year,
      doi: p.externalIds?.DOI || '',
      url: p.externalIds?.DOI ? `https://doi.org/${p.externalIds.DOI}` : '',
      authors: (p.authors || []).map((a: any) => a.name || '').filter(Boolean).join(', '),
      source: 'semantic_scholar', source_label: 'Semantic Scholar'
    })).filter((a: any) => a.title.length > 5)
  } catch(e: any) {
    console.log('SemanticScholar error:', e.message)
    return []
  }
}

// ─── UPDATE PROGRESS ──────────────────────────────────────────────────────────
async function updateProgress(source: string, identifier: string, year: number, page: number, added: number, completed = false) {
  await supabase.from('backfill_progress').upsert({
    source, identifier,
    current_year: year,
    current_page: page,
    total_fetched: added,
    completed,
    last_run: new Date().toISOString()
  }, { onConflict: 'source,identifier' })
}

// ─── FRESH FETCH (last 7 days) ────────────────────────────────────────────────
async function fetchFresh(): Promise<number> {
  let added = 0
  const currentYear = new Date().getFullYear()

  const freshJournals = [
    'Food Quality and Preference', 'Appetite', 'Chemical Senses',
    'Frontiers in Psychology', 'International Journal of Gastronomy and Food Science',
    'Food Research International', 'Journal of Sensory Studies'
  ]
  for (const journal of freshJournals.slice(0, 3)) {
    const { articles } = await fetchScopusPage(journal, currentYear, 0)
    for (const a of articles) {
      const topic = detectTopic(a.title, a.abstract, a.journal)
      if (await saveArticle(a, topic)) added++
      await new Promise(r => setTimeout(r, 150))
    }
  }
  return added
}

// ─── BACKFILL (systematic, progress-tracked) ──────────────────────────────────
async function runBackfill(): Promise<number> {
  let added = 0

  const { data: jobs } = await supabase
    .from('backfill_progress')
    .select('*')
    .eq('completed', false)
    .order('last_run', { ascending: true, nullsFirst: true })
    .limit(20)

  if (!jobs?.length) {
    console.log('All backfill jobs complete!')
    return 0
  }

  for (const job of jobs) {
    const { source, identifier, current_year: year, current_page: page } = job
    let newAdded = 0
    let nextYear = year
    let nextPage = page
    let completed = false

    if (source === 'scopus') {
      const { articles, hasMore } = await fetchScopusPage(identifier, year, page)
      for (const a of articles) {
        const topic = detectTopic(a.title, a.abstract, a.journal)
        if (await saveArticle(a, topic)) newAdded++
        await new Promise(r => setTimeout(r, 200))
      }
      if (hasMore) {
        nextPage = page + 1
      } else {
        nextPage = 0
        nextYear = year - 1
        if (nextYear < MIN_YEAR) completed = true
      }
    }

    else if (source === 'pubmed') {
      const { articles, hasMore } = await fetchPubMedPage(identifier, year, page)
      for (const a of articles) {
        const topic = detectTopic(a.title, a.abstract, a.journal)
        if (await saveArticle(a, topic)) newAdded++
        await new Promise(r => setTimeout(r, 200))
      }
      if (hasMore) {
        nextPage = page + 1
      } else {
        nextPage = 0
        nextYear = year - 1
        if (nextYear < MIN_YEAR) completed = true
      }

      const ssArticles = await fetchSemanticScholar(identifier, year)
      for (const a of ssArticles) {
        const topic = detectTopic(a.title, a.abstract, a.journal)
        if (await saveArticle(a, topic)) newAdded++
        await new Promise(r => setTimeout(r, 150))
      }
    }

    else if (source === 'openalex') {
      const { articles, hasMore } = await fetchOpenAlexPage(identifier, year, page)
      for (const a of articles) {
        const topic = detectTopic(a.title, a.abstract, a.journal)
        if (await saveArticle(a, topic)) newAdded++
        await new Promise(r => setTimeout(r, 200))
      }
      if (hasMore) {
        nextPage = page + 1
      } else {
        nextPage = 0
        nextYear = year - 1
        if (nextYear < MIN_YEAR) completed = true
      }
    }

    await updateProgress(source, identifier, nextYear, nextPage, newAdded, completed)
    added += newAdded
    console.log(`Backfill ${source}/${identifier} ${year} p${page}: +${newAdded} (next: ${nextYear} p${nextPage})`)
    await new Promise(r => setTimeout(r, 300))
  }

  return added
}


// ─── RESEARCHER FETCH ────────────────────────────────────────────────────────
async function fetchResearchers(): Promise<number> {
  let added = 0
  try {
    const { data: researchers } = await supabase
      .from('researchers')
      .select('*')
      .eq('completed', false)
      .order('priority', { ascending: false })
      .limit(2)

    if (!researchers?.length) return 0

    for (const researcher of researchers) {
      const page = researcher.current_page || 0
      const year = researcher.current_year || 2025
      const start = page * 25

      if (!researcher.scopus_author_id) continue

      let query = `AU-ID(${researcher.scopus_author_id})`

      const url = `https://api.elsevier.com/content/search/scopus?query=${encodeURIComponent(query)}&count=25&start=${start}&sort=-coverDate&apiKey=${SCOPUS_KEY}&httpAccept=application%2Fjson`

      const r = await fetch(url)
      if (!r.ok) {
        console.log(`Researcher ${researcher.name}: HTTP ${r.status}`)
        continue
      }

      const d = await r.json()
      const entries = d['search-results']?.entry || []
      const total = parseInt(d['search-results']?.['opensearch:totalResults'] || '0')
      const hasMore = (start + 25) < total

      console.log(`Researcher ${researcher.name} ${year} p${page}: ${entries.length}/${total}`)

      // Samma Scopus Search API som fetchScopusPage — dela extraktionen så
      // affilname/-city/-country landar i researcher-hämtade artiklar också.
      // Utan detta hamnade Anders 13 egna publikationer (och alla andra
      // AU-ID-fetchade) med institutions=null trots att svaret innehåller
      // affiliation-arrayen.
      for (const e of entries) {
        const article = mapScopusEntry(e, '', year)
        const topic = detectTopic(article.title, article.abstract, article.journal)
        if (await saveArticle(article, topic)) added++
        await new Promise(r => setTimeout(r, 150))
      }

      let nextPage = hasMore ? page + 1 : 0
      let nextYear = hasMore ? year : year - 1
      let completed = !hasMore && nextYear < MIN_YEAR

      await supabase.from('researchers').update({
        current_page: nextPage,
        current_year: nextYear,
        completed,
        total_fetched: (researcher.total_fetched || 0) + added,
        last_run: new Date().toISOString()
      }).eq('id', researcher.id)
    }
  } catch(e: any) {
    console.log('Researcher fetch error:', e.message)
  }
  return added
}

// ─── MAIN ─────────────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  const body = await req.json().catch(() => ({}))

  const researcherAdded = await fetchResearchers()
  const freshAdded = await fetchFresh()
  console.log(`Fresh fetch: +${freshAdded}`)

  const backfillAdded = await runBackfill()
  console.log(`Backfill: +${backfillAdded}`)

  const total = freshAdded + backfillAdded

  const { data: remaining } = await supabase
    .from('backfill_progress')
    .select('source, identifier, current_year, completed')
    .eq('completed', false)
    .order('current_year', { ascending: false })
    .limit(5)

  const { count } = await supabase
    .from('articles')
    .select('id', { count: 'exact', head: true })

  return new Response(JSON.stringify({
    ok: true,
    added: total,
    researchers: researcherAdded,
    fresh: freshAdded,
    backfill: backfillAdded,
    total_articles: count,
    next_jobs: remaining
  }), { headers: { 'Content-Type': 'application/json' } })
})
