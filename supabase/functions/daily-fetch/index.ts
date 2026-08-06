import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { openAlexToKeywords } from '../_shared/openalex-terms.ts'

const SB_URL = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''

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

// HTML-entiteter i title/abstract/journal/authors — 305 rader affekterade
// vid mätning 2026-08-06 (0,9 % av 34 722 relevanta artiklar). Källor:
// Crossref/Scopus/PubMed skickar ibland `&lt;em&gt;Vitis vinifera&lt;/em&gt;`
// för italic-latinska binomen, `&amp;` för ampersand. Frontendens
// _apaCleanTitle strippade bara råa <tag>, inte entiteter, så både overlay
// och APA-referens visade literal `<em>Vitis vinifera</em>`.
//
// cleanText avkodar top-6 named entities (&amp; sist så double-escape
// undviks) + numeriska (&#\d+;) + strippar kvarvarande HTML-taggar. Samma
// logik som html_entity_decode_strip SQL-funktionen i migration
// 20260806140000. Frontend har en tredje kopia (cleanTextField via textarea)
// som defensivt fångar entiteter vi missar här — trippelbälte, samma
// resonemang som topic_keywords: tabell + daily-fetch-loader + hardcoded
// fallback.
function cleanText(s: string | null | undefined): string {
  if (!s) return ''
  return String(s)
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#39;/g, "'")
    .replace(/&#(\d+);/g, (_, n) => {
      const c = parseInt(n, 10)
      return c > 0 && c < 0x110000 ? String.fromCodePoint(c) : ''
    })
    .replace(/&amp;/g, '&')
    .replace(/<[^>]+>/g, '')
    .replace(/\s+/g, ' ')
    .trim()
}

function isBlockedJournal(journal: string, title: string, abstract: string): boolean {
  if(!journal) return false
  const j = journal.toLowerCase().trim()
  if(BLOCKED_JOURNALS.has(j)) return true
  // Breda journaler kräver mat/gastronomi-sökord
  const BROAD = ['frontiers in psychology','frontiers in neuroscience','sustainability','molecules','nutrients','antioxidants','foods']
  if(BROAD.includes(j) && !FOOD_KEYWORDS.test(title + ' ' + (abstract||''))) return true
  return false
}

// Vissa upstream-flöden (Scopus, PubMed, Semantic Scholar) returnerar ibland
// DOI-fältet som full URL istället för raw DOI. Utan strippning blev
// `url = https://doi.org/${doi}` dubbelprefixat → 1 019 korrupta rader i prod
// juli 2026 innan detta fångades. While-loopen tål även flerfaldig prefix
// (rader som redan ingesterats innan fixen och hämtats tillbaka).
function normalizeDoi(raw: string): string {
  let s = (raw || '').trim()
  while(/^https?:\/\/(?:dx\.)?doi\.org\//i.test(s)) {
    s = s.replace(/^https?:\/\/(?:dx\.)?doi\.org\//i, '')
  }
  return s
}
const SCOPUS_KEY = Deno.env.get('SCOPUS_KEY') || ''

// Per-invocation räknare för saveArticle:s rejection-paths. Nollställs
// överst i Deno.serve — modulscopet håller annars kvar värdet mellan
// cron-körningar. Rapporteras i slutsvaret så tyst 0-avkastning har
// diagnos-signaler.
//
// Namnen är precisa: förra generationens "skipped_duplicate" täckte bara
// upsert-race-fallet och lästes felaktigt som "hittade dups" (rota till
// två-dygns-stillestånd 2026-08-04 där isDuplicate-avvisningar var tysta).
let skippedShortTitle = 0     // rad 191: title < 10 tecken
let skippedRelevance  = 0     // rad 194: relevanceReject-gate (BROAD-journal, off-topic, blocked)
let duplicateInDb     = 0     // rad 200: isDuplicate pre-check hittade existerande DOI/titel
let skippedUrlConflict = 0    // rad 265: upsert onConflict='url' → ignoreDuplicates hit (race)

// Kommersiell produkt fr.o.m. 2026-07-10: Scopus akademiska API-nyckel får
// inte längre användas för hämtning. Alla call sites som träffar
// api.elsevier.com short-circuitar när SCOPUS_ENABLED = false. Koden för
// fetchScopusPage/fetchResearchers/mapScopusEntry ligger kvar tills
// OpenAlex-migreringen är klar och kan tas bort helt. Flippa denna flagga
// bara om nyckeln blir tillåten igen (den blir det inte).
const SCOPUS_ENABLED = false
// Scopus indexeras praktiskt från tidigt 1970-tal, PubMed från 1966. Under
// 1970 finns i vår domän i princip inget (Chemical Senses börjar 1974,
// Journal of Texture Studies 1969, moderna sensory-vetenskapen är i mångt
// en 1980-tals-företeelse). 1970 är gränsen där tomma ticks tar över — vi
// behöver inte ticka längre. completed = true sätts när svepet decrementat
// nedanför denna floor och faller ur runBackfills pool.
const MIN_YEAR = 1970

const supabase = createClient(SB_URL, SB_SERVICE_KEY)

// ─── TOPIC DETECTION ──────────────────────────────────────────────────────────
// KÄLLA TILL SANNING: public.topic_keywords-tabellen (migration 20260805140000
// + tillägg i 150000 + 160000). Läses vid varje Deno.serve-invocation och
// cachas i modul-scope (CURRENT_TOPICS). Reclassify-migrationen 20260805200000
// använder samma tabell för sin argmax — DAILY-FETCH OCH RECLASSIFY DELAR
// KÄLLA SÅ KLASSNINGEN INTE GLIDER ISÄR från dag ett.
//
// Fallback: TOPICS-const nedan är seed-datat från runda 1. Aktiveras BARA om
// tabell-fetchen misslyckas (extension saknas, connection issue). Frusen 2026-
// 08-05 — nya keywords läggs BARA till i tabellen framåt. Om hardcoded och
// tabell glider isär > 3 månader, riv fallback:en eller resynca.
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

// Runtime-cache. Fylls i loadTopicsFromDB() vid Deno.serve-start; om det
// misslyckas eller om vi kallar detectTopic INNAN load har körts (fanns
// tidigare kod-vägar med sync-anrop utanför main-request-scope), faller vi
// tillbaka till TOPICS ovan.
let CURRENT_TOPICS: Record<string, string[]> = TOPICS

async function loadTopicsFromDB(): Promise<void> {
  try {
    const r = await supabase.from('topic_keywords').select('topic, keyword')
    if (r.error) throw new Error(r.error.message)
    if (!r.data || r.data.length === 0) throw new Error('empty topic_keywords')
    const dict: Record<string, string[]> = {}
    for (const row of r.data) {
      if (!dict[row.topic]) dict[row.topic] = []
      dict[row.topic].push(row.keyword)
    }
    CURRENT_TOPICS = dict
    console.log(`loadTopicsFromDB: ${Object.keys(dict).length} topics, ${r.data.length} keywords laddade`)
  } catch (e: any) {
    console.log(`loadTopicsFromDB failed (${e.message}) — fallback till hardcoded TOPICS`)
    CURRENT_TOPICS = TOPICS
  }
}

function detectTopic(title: string, abstract: string, journal: string): string {
  const text = `${title} ${abstract} ${journal}`.toLowerCase()
  // Default 'uncategorized' istället för 'gastronomy'. Tidigare fick allt
  // som inte träffade någon TOPICS-nyckel 'gastronomy' by default — det
  // gjorde att kinesiska aktieindex, taktegel-antikvariat och tusentals
  // andra rader hamnade i gastronomy-topic'en utan att verkligen matcha.
  // 'uncategorized' är en ny kategori som saknas i TOPIC_LABELS/topicColors
  // — frontend faller tillbaka till raw-strängen respektive gold-defaulten
  // så inget kraschar; det syns bara som "uncategorized" i etiketter.
  let bestTopic = 'uncategorized'
  let bestScore = 0
  for (const [topic, keywords] of Object.entries(CURRENT_TOPICS)) {
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

// analyzeWithClaude flyttades ut 2026-08-04 till supabase/functions/
// fill-daily-analysis/index.ts. Se saveArticle-kommentaren nedan. Fn:en
// och ANTHROPIC_KEY-importen borttagna som död kod — enda kvarvarande
// externa AI-call i denna fn är extraktion (openAlexToKeywords) som är
// deterministisk mappning.

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
    // Normalisera text-fält från alla källor innan validering och dup-check.
    // Se cleanText-kommentaren för bakgrund. Muteras på plats så resten av
    // saveArticle och alla downstream-callers (relevanceReject, isDuplicate,
    // upsert) opererar på rena strängar. length-checken nedan gäller alltså
    // den rensade titeln — "<em>Volatile</em>" (13 tecken) blir "Volatile"
    // (8 tecken) och skippas som förr, vilket är rätt: en riktig titel
    // förlorar inte tio tecken bara för att italics strippas.
    article.title    = cleanText(article.title)
    article.abstract = cleanText(article.abstract)
    article.journal  = cleanText(article.journal)
    article.authors  = cleanText(article.authors)

    if (!article.title || article.title.length < 10) {
      skippedShortTitle++
      return false
    }

    // ── RELEVANSGRIND (gäller ALLA källor) ──
    const reject = relevanceReject(article)
    if (reject) {
      console.log(`Skipped (${reject}): ${article.title.slice(0,60)} [${article.journal || '-'}]`)
      skippedRelevance++
      return false
    }

    if (await isDuplicate(article.doi || '', article.title)) {
      duplicateInDb++
      return false
    }

    // insight/application/limitation/limit_type/study_type fylls INTE här
    // längre. Tidigare analyzeWithClaude-anrop här inne gav 1-2 s per ny
    // artikel → daily-fetch:s wallclock klev över Supabase-gatewayens
    // 150 s IDLE_TIMEOUT vid burstar av nya artiklar, skrev partiellt,
    // sex tysta fel före upptäckt (2026-08-04).
    //
    // fill-daily-analysis (skapad + rollbackad samma dag, se migration
    // 20260804160000_drop_fill_daily_analysis.sql) skulle täcka fältet men
    // mätning visade att 98,7 % av populationen redan har core_claim som
    // dominerar renderingen. study_type sätts av pipeline och backfill-
    // haiku-sci; application används inte i frontend; insight är fallback
    // till core_claim i alla renderingar. Nya rader landar med tomma
    // strängar för dessa fält — frontend hanterar det.
    const analysis: any = {}

    // Sanity: en trunkerad Scopus-parser gav 13 540 rader med bara ett namn
    // i authors innan commit ffa7ab7. Backfillades via OpenAlex, men
    // upptäcktes månader efter det att APA-referenser blivit fel i
    // produkten. Logga varje singel-namns-write så nästa parser-regression
    // syns i loggen direkt — inte via en användarrapport.
    const rawAuthors = (article.authors || '').trim()
    if (rawAuthors && !rawAuthors.includes(',')) {
      console.log(`Author-sanity: singel-namn "${rawAuthors}" [${article.source}] ${article.title.slice(0, 60)}`)
    }

    // upsert med ignoreDuplicates i stället för ren insert: uq_articles_url
    // (partial unique på url where url is not null) faller ut i konflikt när
    // isDuplicate-pre-checken racas av två samtidiga cron-körningar.
    // ignoreDuplicates behåller den befintliga raden orörd — den kan ha blivit
    // TRIAD-analyserad eller ha bättre författarlista från annan källa. .select
    // ('id') låter oss skilja på insert (data=[{id}]) och konflikt (data=[]).
    //
    // url: null (inte tom sträng) eftersom partial-indexet ignorerar null; tom
    // sträng räknas som ett värde och 283 sådana kolliderade i prod 2026-08-02.
    const { data, error } = await supabase.from('articles').upsert({
      title: article.title,
      authors: article.authors || '',
      journal: article.journal || '',
      year: article.year || null,
      topic,
      source: article.source,
      source_label: article.source_label,
      url: article.url || null,
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
      // OpenAlex-vägen fyller institution_openalex_ids parallellt med
      // institutions[] (samma index). Scopus/PubMed/S2 skickar inte fältet
      // → null → backfill-affiliations kan i teorin fylla det senare
      // (predikat institutions IS NULL — så bara icke-OA-vägar där institutions
      // är tom). För OA-vägen är detta enda skrivningen; utan den återväxer
      // populationen "TRIAD-artikel utan institution_openalex_ids" varje dag.
      institution_openalex_ids: article.institution_openalex_ids?.length ? article.institution_openalex_ids : null,
      institution_coords: article.institution_coords?.length ? article.institution_coords : null,
      affiliations: article.affiliations?.length ? article.affiliations : null,
      primary_institution: article.primary_institution || null,
      country: article.country || null,
      countries: article.countries?.length ? article.countries : null,
      // Keywords från källan (OpenAlex-concepts, filtrerade i fetchOpenAlex-
      // Page). PubMed/S2/Scopus skickar inte article.keywords → null →
      // pipeline runSci fyller senare via merge. Så framåt-fixen påverkar
      // bara OpenAlex-vägen; övriga källor får samma beteende som förr.
      keywords: article.keywords?.length ? article.keywords : null,
      fetched_at: new Date().toISOString()
    }, { onConflict: 'url', ignoreDuplicates: true })
      .select('id')
    if (error) { console.log('Save error:', error.message); return false }
    if (!data?.length) { skippedUrlConflict++; return false }
    return true
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
  // Scopus author-lista finns bara i COMPLETE view (se URL-parametern i
  // fetchScopusPage/fetchResearchers). STANDARD view ger enbart dc:creator,
  // vilket gav 100 % singelförfattare i 13 540 rader från prod juli 2026 —
  // hela APA-referensen blev fel. Läses defensivt: top-level e.author
  // (COMPLETE), sen nested e.authors.author (äldre svarformat), sen
  // dc:creator som sista fallback. Wrap enkelfall — Scopus returnerar
  // objekt (inte enelements-array) när det bara finns en författare.
  const rawAuthors = e['author'] ?? e['authors']?.author ?? []
  const authorList = Array.isArray(rawAuthors) ? rawAuthors : [rawAuthors]
  const authors = authorList.map((a: any) => {
    const given = (a['given-name'] || a['ce:given-name'] || a['initials'] || '').trim()
    const surname = (a['surname'] || '').trim()
    return `${given} ${surname}`.trim()
  }).filter(Boolean).join(', ') || e['dc:creator'] || ''
  const doi = normalizeDoi(e['prism:doi'] || '')
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
    // view=COMPLETE krävs för att få hela författararrayen (annars bara
    // dc:creator = första författaren). Kräver institutional/subscription
    // access; utan det svarar Scopus 400. Vid re-enable av SCOPUS_ENABLED
    // efter juli-2026-pausen: verifiera att SCOPUS_KEY har COMPLETE-rätt.
    const url = `https://api.elsevier.com/content/search/scopus?query=${query}&count=25&start=${start}&sort=-coverDate&view=COMPLETE&apiKey=${SCOPUS_KEY}&httpAccept=application%2Fjson`

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
      const doi = normalizeDoi(articleXml.match(/<ELocationID EIdType="doi"[^>]*>([\s\S]*?)<\/ELocationID>/)?.[1] || '')
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

// OpenAlex serves the abstract as a positional inverted index — {word: [pos,
// pos, ...]}. Reconstruct linearly: for each word push it at every position,
// sort by position, join with spaces. Truthy checks first because a) many
// works have abstract_inverted_index=null (no abstract available), b) some
// return an empty object {}, c) rare bad shapes should degrade to '' rather
// than throw and abort the mapper for a whole page.
function reconstructAbstract(inv: Record<string, number[]> | null | undefined): string {
  if (!inv || typeof inv !== 'object') return ''
  const positions: [number, string][] = []
  for (const [word, indices] of Object.entries(inv)) {
    if (!Array.isArray(indices)) continue
    for (const i of indices) if (typeof i === 'number') positions.push([i, word])
  }
  if (!positions.length) return ''
  positions.sort((a, b) => a[0] - b[0])
  return positions.map(([, w]) => w).join(' ')
}

// ─── OPENALEX FETCH (with year + pagination) ──────────────────────────────────
// direction ('backward'|'forward'):
//   - Styr sort på fritext-vägen (backward=cited_by_count, forward=publication_date)
//     så nya papers hittas först i forward-lägen. Source-id-vägen har alltid
//     publication_date:desc.
//   - Aktiverar from_publication_date-filter i forward + lastRun-satt.
//     ANSTÄNDIGHETSFRÅGA MOT OPENALEX: utan detta filter refetchas sida 0
//     varje tick när ett forward-jobb ligger på innevarande år (uttömt) —
//     ~67 000 anrop/dygn för 7 jobb var 3:e min. Med filtret hämtas bara
//     det som publicerats sedan senaste sväng (1-dygns överlapp mot
//     klockglidning, url-unique-constraint fångar dubbletter).
async function fetchOpenAlexPage(
  query: string,
  year: number,
  page: number,
  direction: 'backward'|'forward' = 'backward',
  lastRun?: string | null,
): Promise<{articles: any[], hasMore: boolean}> {
  try {
    const perPage = 20
    // Dual-mode. Identifierare som matchar ^S\d+$ tolkas som OpenAlex
    // source-id och ger journal-scoped svep (exakt tidskrift, år för år,
    // deterministisk paginering via publication_date:desc). Allt annat
    // är fritext-svep (topic-backfill via search=).
    const isSourceId = /^S\d+$/.test(query)
    // mailto → OpenAlex "polite pool": högre kvot, snabbare svar, gratis.
    const mailto = 'anders@crichton-fock.com'

    const filters: string[] = []
    if (isSourceId) {
      filters.push(`primary_location.source.id:${query}`)
      filters.push(`publication_year:${year}`)
    } else {
      filters.push('type:article')
      filters.push(`publication_year:${year}`)
    }
    if (direction === 'forward' && lastRun) {
      // Publikationsdatum ≥ last_run - 1 dag. 1-dygns marginal fångar
      // rader som publicerats mellan senaste svepets fetch och now().
      const d = new Date(lastRun)
      d.setUTCDate(d.getUTCDate() - 1)
      filters.push(`from_publication_date:${d.toISOString().slice(0, 10)}`)
    }

    const sort = (direction === 'backward' && !isSourceId)
      ? 'cited_by_count:desc'   // klassiskt bakåt-fritext: kärnan först
      : 'publication_date:desc'  // alla andra kombinationer: nyaste först
    const searchParam = isSourceId ? '' : `&search=${encodeURIComponent(query)}`

    const url = `https://api.openalex.org/works?per-page=${perPage}&page=${page + 1}${searchParam}&filter=${filters.join(',')}&sort=${sort}&mailto=${mailto}`
    const r = await fetch(url, { headers: { 'User-Agent': 'GustoScience/1.0 (gusto.science)' } })
    if (!r.ok) return { articles: [], hasMore: false }
    const d = await r.json()
    const total = d.meta?.count || 0
    const hasMore = ((page + 1) * perPage) < total

    const articles = (d.results || []).map((w: any) => {
      const authorships = w.authorships || []
      const flatInsts = authorships.flatMap((a: any) => a.institutions || [])
      // institutions[] och institution_openalex_ids[] byggs som PARALLELLA
      // arrays deduped på display_name — samma index i båda refererar till
      // samma institution. Utan id-listan har vi ingen väg att slå upp
      // geo-koordinater (OpenAlex /works/-svaret returnerar INTE geo på
      // nested institutions, bara id/name/country_code — geo ligger på
      // /institutions/{id}). Backfill-affiliations skriver samma parallell-
      // array; matcha logiken exakt så alla vägar in i articles har
      // konsistent format. Kort form (strippad openalex.org/-prefix) för
      // renare lagring; API:t tar båda.
      const seen = new Set<string>()
      const institutions: string[] = []
      const institution_openalex_ids: string[] = []
      for (const inst of flatInsts) {
        const name = inst?.display_name
        if (!name || seen.has(name)) continue
        seen.add(name)
        institutions.push(name)
        const rawId = (inst?.id || '') as string
        institution_openalex_ids.push(rawId.replace(/^https?:\/\/openalex\.org\//, ''))
      }
      // institution_coords lämnas null — /works/ har inte geo. Fylls
      // separat via bulk-UPDATE mot openalex_institutions-tabellen (Fas 3
      // 2026-08-02) som resolverar id → lat/lng. Den gamla flatInsts.filter
      // (i => i.geo?.latitude)-koden var tyst felkälla (skrev alltid tom
      // array) och togs bort samtidigt som backfill-affiliations fick
      // samma fix.
      const countries = [...new Set(flatInsts.map((i: any) => i.country_code).filter(Boolean))] as string[]
      // raw_affiliation_strings preserves department/campus text ("Örebro
      // University, Grythyttan Campus") that display_name flattens away.
      const affiliations = [...new Set(
        authorships.flatMap((a: any) => a.raw_affiliation_strings || []).filter(Boolean)
      )] as string[]
      // OpenAlex topics + keywords → keywords, med concepts som fallback vid
      // < MIN_TERMS (hybrid — se _shared/openalex-terms.ts). Delad logik med
      // Del 3-backfillen så nya och backfillade artiklar får identisk grund.
      const openAlexKeywords = openAlexToKeywords(w)
      return {
        title: w.title || '',
        // OpenAlex returns abstract as abstract_inverted_index, not as a
        // string field — the old `w.abstract || ''` was always ''. Rebuild
        // the text so new OpenAlex-sourced articles land with abstract,
        // available for relevance-check and the map-institution flow.
        abstract: reconstructAbstract(w.abstract_inverted_index),
        journal: w.primary_location?.source?.display_name || '',
        year: w.publication_year || year,
        doi: normalizeDoi(w.doi || ''),
        url: w.doi || w.id || '',
        authors: authorships.map((a: any) => a.author?.display_name || '').filter(Boolean).join(', '),
        country: countries[0] || '',
        institutions,
        institution_openalex_ids,
        institution_coords: null,
        countries,
        affiliations,
        primary_institution: institutions[0] || null,
        keywords: openAlexKeywords,
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
    return (d.data || []).map((p: any) => {
      const doi = normalizeDoi(p.externalIds?.DOI || '')
      return {
        title: p.title || '',
        abstract: p.abstract || '',
        journal: p.venue || '',
        year: p.year || year,
        doi,
        url: doi ? `https://doi.org/${doi}` : '',
        authors: (p.authors || []).map((a: any) => a.name || '').filter(Boolean).join(', '),
        source: 'semantic_scholar', source_label: 'Semantic Scholar'
      }
    }).filter((a: any) => a.title.length > 5)
  } catch(e: any) {
    console.log('SemanticScholar error:', e.message)
    return []
  }
}

// ─── UPDATE PROGRESS ──────────────────────────────────────────────────────────
// Kumulativ total_fetched via RPC (migration 20260804170000). Tidigare
// direkt-upsert skrev `total_fetched: added` → värdet från senaste körningen,
// inte kumulativt. Sex öppna openalex-jobb visade total_fetched=0 trots att
// current_page rört sig i veckor, för att alla senaste tick var dups.
// RPC:n gör `total_fetched = existing + added` server-side.
async function updateProgress(source: string, identifier: string, year: number, page: number, added: number, completed = false, direction: 'backward'|'forward' = 'backward') {
  // p_direction default 'backward' i RPC-signaturen (migration 20260805120000)
  // så gamla anropare utan direction fortsätter fungera. Vi skickar alltid
  // eftersom on-conflict-target är (source, identifier, direction) — utan
  // direction skulle vi kunna trigga fel unique-target vid race.
  const { error } = await supabase.rpc('advance_backfill_progress', {
    p_source: source,
    p_identifier: identifier,
    p_year: year,
    p_page: page,
    p_added: added,
    p_completed: completed,
    p_direction: direction,
  })
  if (error) console.log(`updateProgress RPC error ${source}/${identifier} [${direction}]: ${error.message}`)
}

// ─── FRESH FETCH (last 7 days) ────────────────────────────────────────────────
async function fetchFresh(): Promise<number> {
  if (!SCOPUS_ENABLED) {
    console.log('fetchFresh: skipped (SCOPUS_ENABLED=false)')
    return 0
  }
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

  // Exkludera scopus-rader ur .limit(20)-rotationen. De skulle annars
  // stjäla platser från pubmed/openalex-jobb (samma svält vi lagade förr).
  // In-branch-gaten nedan är kvar som säkerhetsnät ifall raden återinförs.
  const { data: jobs } = await supabase
    .from('backfill_progress')
    .select('*')
    .eq('completed', false)
    .neq('source', 'scopus')
    .order('last_run', { ascending: true, nullsFirst: true })
    .limit(20)

  if (!jobs?.length) {
    console.log('All backfill jobs complete!')
    return 0
  }

  for (const job of jobs) {
    const {
      source, identifier, current_year: year, current_page: page,
      direction = 'backward', last_run: lastRun = null,
    } = job
    let newAdded = 0
    let nextYear = year
    let nextPage = page
    let completed = false

    if (source === 'scopus') {
      if (!SCOPUS_ENABLED) {
        console.log(`Backfill skip scopus/${identifier}: SCOPUS_ENABLED=false`)
        continue  // pausar utan progress-uppdatering; jobbet ligger kvar
      }
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
      const { articles, hasMore } = await fetchOpenAlexPage(identifier, year, page, direction, lastRun)
      for (const a of articles) {
        const topic = detectTopic(a.title, a.abstract, a.journal)
        if (await saveArticle(a, topic)) newAdded++
        await new Promise(r => setTimeout(r, 200))
      }
      console.log(`Backfill openalex/${identifier} [${direction}] ${year} p${page}: articles=${articles.length} hasMore=${hasMore} newAdded=${newAdded}`)

      if (direction === 'forward') {
        // Forward: sida uttömd → nästa år om vi ligger bakom current;
        // annars stanna på samma år så from_publication_date-filtret
        // fångar nya publikationer nästa cron-tick. Aldrig completed —
        // forward-jobb är eviga bevakningar.
        if (articles.length === 0 || !hasMore) {
          const currentYr = new Date().getFullYear()
          nextPage = 0
          nextYear = year < currentYr ? year + 1 : year
        } else {
          nextPage = page + 1
        }
      } else {
        // Backward: safety net vid 0 artiklar (samma som !hasMore) — svep
        // får aldrig fastna på ett år.
        if (articles.length === 0 || !hasMore) {
          nextPage = 0
          nextYear = year - 1
          if (nextYear < MIN_YEAR) completed = true
        } else {
          nextPage = page + 1
        }
      }
    }

    await updateProgress(source, identifier, nextYear, nextPage, newAdded, completed, direction)
    added += newAdded
    console.log(`Backfill ${source}/${identifier} ${year} p${page}: +${newAdded} (next: ${nextYear} p${nextPage})`)
    await new Promise(r => setTimeout(r, 300))
  }

  return added
}


// ─── RESEARCHER FETCH ────────────────────────────────────────────────────────
async function fetchResearchers(): Promise<number> {
  if (!SCOPUS_ENABLED) {
    console.log('fetchResearchers: skipped (SCOPUS_ENABLED=false)')
    return 0
  }
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

      const url = `https://api.elsevier.com/content/search/scopus?query=${encodeURIComponent(query)}&count=25&start=${start}&sort=-coverDate&view=COMPLETE&apiKey=${SCOPUS_KEY}&httpAccept=application%2Fjson`

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
  skippedShortTitle = 0
  skippedRelevance  = 0
  duplicateInDb     = 0
  skippedUrlConflict = 0

  // Ladda topic_keywords från DB innan detectTopic anropas i pipeline-vägarna.
  // Cachas i CURRENT_TOPICS (modul-scope) för hela denna invocation.
  // Fallback till hardcoded TOPICS om DB-fetch fails — se loadTopicsFromDB.
  await loadTopicsFromDB()

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
    // Per-invocation rejection-räknare (renamed 2026-08-04 för att lösa
    // "skipped_duplicate"-tvetydigheten som doldes tyst 0-avkastning i
    // två dygn). added=0 + duplicate_in_db > 0 = källa returnerar men allt
    // finns redan (backfill uttömd). added=0 + skipped_relevance > 0 =
    // källa returnerar off-topic. added=0 + samtliga räknare 0 = källa
    // returnerar tomt (safety-net decrementerar year i runBackfill).
    duplicate_in_db:      duplicateInDb,
    skipped_relevance:    skippedRelevance,
    skipped_url_conflict: skippedUrlConflict,
    skipped_short_title:  skippedShortTitle,
    total_articles: count,
    next_jobs: remaining
  }), { headers: { 'Content-Type': 'application/json' } })
})
