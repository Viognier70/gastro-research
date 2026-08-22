// scripts/send-weekly-digest.ts
// ─────────────────────────────────────────────────────────────────────────
// ORDER 122 (2026-08-21) — veckobrev till profiler med roll + aktiv digest.
//
// Fristående Deno-skript. Följer samma pattern som scripts/repair-abstracts.ts
// och two-track-test.ts. Cron-triggning från Supabase Dashboard kan
// wrapas i en tunn edge-fn senare — utanför scope här.
//
// FLÖDE PER MOTTAGARE:
//   A. Fem artiklar — nya sedan last_digest_at (eller senaste 7 dagarna
//      om null), rankade på relevance_sci_<science-role>. Filter:
//      episteme_<science-role> not null, irrelevant not true. Topic-
//      filter från saved_articles-topics (två vanligaste) ENDAST om
//      user har >= 3 sparade — annars bara rank på roll.
//   B. Research Pulse — 4 trendande keywords via get_trending_keywords
//      RPC (rollagnostisk). Cacheas ONE gång för hela körningen.
//   C. Veckans omdöme — phronesis-texten från den högst rankade artikeln
//      (articles[0] från Section A). Skippas om A är tomt.
//   D. Institutionsobservation — institution som publicerat mest inom
//      user:s vanligaste topic senaste månaden. Skippas om user har 0
//      sparade eller om aggregatet ger 0 träffar.
//   E. Sparat-påminnelse — 2 artiklar via match_related-RPC seedad från
//      user:s 3 senast sparade. Filtrerar bort redan sparade. Skippas
//      om user har 0 sparade eller om match_related ger < 1 unik.
//
// ROBUSTHET: A måste finnas för att brevet ska skickas alls. B krävs
//   också (om get_trending_keywords ger 0 → cache-array är tom och
//   sektionen skippas — mycket osannolikt scenario). C/D/E toleras
//   tomma — sektionerna droppas ur HTML:en tyst.
//
// FREE vs PRO:
//   isPro = profiles.is_pro OR (trial_ends_at > now())
//   Free  → rubrik + core_claim per artikel
//   Pro   → dessutom TRIAD-fält (episteme/techne/phronesis för rollen)
//
// AVSÄNDNING: Brevo /v3/smtp/email (transactional, per-recipient).
//   Avsändare research@gusto.science med namn "The Gusto Weekly".
//   Unsubscribe-länk: https://gusto.science/unsubscribe?t=<digest_token>
//   sist i varje brev (statisk sida från ORDER 121 hostas där).
//
// DRY-RUN som default. --send krävs för att kalla Brevo + uppdatera
//   last_digest_at. Dry-run skriver full HTML till out/digest-preview/
//   <email>.html per mottagare för manuell granskning.
//
// KÖRNING:
//   Dry-run:
//     SUPABASE_SERVICE_ROLE_KEY=eyJ... BREVO_API_KEY=xkeysib-... \
//       deno run --allow-net --allow-env --allow-read --allow-write \
//       scripts/send-weekly-digest.ts
//   Apply:
//     SUPABASE_SERVICE_ROLE_KEY=eyJ... BREVO_API_KEY=xkeysib-... \
//       deno run --allow-net --allow-env --allow-read --allow-write \
//       scripts/send-weekly-digest.ts --send
// ─────────────────────────────────────────────────────────────────────────

// ── Konfiguration ─────────────────────────────────────────────────────────
const SB_URL     = Deno.env.get('SUPABASE_URL') || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_KEY     = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
const BREVO_KEY  = Deno.env.get('BREVO_API_KEY') || ''
const APPLY      = Deno.args.includes('--send')

const SENDER_EMAIL = 'research@gusto.science'
const SENDER_NAME  = 'The Gusto Weekly'
const UNSUB_BASE   = 'https://gusto.science/unsubscribe'
const OUT_DIR      = 'out/digest-preview'
const PER_SEND_MS  = 200        // ~5 req/s mot Brevo — väl under 400/s-taket
const FALLBACK_SINCE_DAYS = 7   // om last_digest_at IS NULL

if (!SB_KEY) { console.error('Missing SUPABASE_SERVICE_ROLE_KEY'); Deno.exit(2) }
if (APPLY && !BREVO_KEY) { console.error('Missing BREVO_API_KEY (krävs för --send)'); Deno.exit(2) }

// ── Roll-mappning ─────────────────────────────────────────────────────────
// chip → science-namn för DB-kolumner. Matchar CHECK-constraint i
// migration 20260821120000_profile_role_and_digest.sql.
const ROLE_TO_SCIENCE: Record<string, string> = {
  sommelier:       'sensory_pro',
  chef:            'culinary_pro',
  gastronomy:      'gastronomy_culture',
  fb_manager:      'hospitality_mgmt',
  food_researcher: 'educator_researcher',
}
const ROLE_LABEL: Record<string, string> = {
  sommelier:       'Sommelier',
  chef:            'Chef',
  gastronomy:      'Meal Creator',
  fb_manager:      'Hospitality Management',
  food_researcher: 'Food Researcher & Educator',
}
// ORDER 124: science-slug → human label. Speglar ROLE_LABEL men indexeras
// på DB-fältets namn så vi kan rensa slug-läckage från Sonnet/Haiku-svar
// (t.ex. "For you as a culinary_pro" → "For you as a Chef").
const SCIENCE_TO_LABEL: Record<string, string> = {
  sensory_pro:         'Sommelier',
  culinary_pro:        'Chef',
  gastronomy_culture:  'Meal Creator',
  hospitality_mgmt:    'Hospitality Management',
  educator_researcher: 'Food Researcher & Educator',
}
// Rensa science-slug ur AI-genererad text som ska visas för användaren.
// Rättar de 25 befintliga syntheses-raderna (prompten skickade dbRole
// rakt in), och skyddar mot framtida drift även om prompten uppdateras.
function humanizeRoleSlugs(text: string | null | undefined): string {
  if (!text) return ''
  return String(text).replace(
    /\b(sensory_pro|culinary_pro|gastronomy_culture|hospitality_mgmt|educator_researcher)\b/g,
    m => SCIENCE_TO_LABEL[m] || m
  )
}
// Item 3: hälsning "Hi <name>," kräver att namnet ser ut som ett namn.
// "ds", "x", tomsträng, siffror etc → fall back till plain "Hi,".
// Kriterier (ORDER 125-skärpning):
//   - minst 3 tecken efter trim (var 2 — "ds" passade genom)
//   - måste innehålla minst en bokstav (unicode-aware Å/Ä/Ö m.fl.)
//   - vid exakt 3 tecken krävs minst en versal (t !== t.toLowerCase())
//     — ett tvåbokstavsnamn är i praktiken alltid testkonto/slarv,
//     ett trebokstavsnamn i lowercase (abc, xyz, def) likaså. Namn
//     >=4 tecken släpps oavsett skiftläge — "test" kan vara Testa,
//     "adam" kan vara Adam skrivet slarvigt.
function isValidGreetingName(n: string | null | undefined): boolean {
  if (!n) return false
  const t = n.trim()
  if (t.length < 3) return false
  if (!/[A-Za-zÀ-ÖØ-öø-ÿ]/.test(t)) return false
  if (t.length === 3 && t === t.toLowerCase()) return false
  return true
}

// ── Typer ─────────────────────────────────────────────────────────────────
type Recipient = {
  id:             string
  email:          string
  display_name:   string | null
  role:           string   // chip-slug
  is_pro:         boolean
  trial_ends_at:  string | null
  digest_token:   string
  last_digest_at: string | null
}
type Article = {
  id:             string
  title:          string
  headline_en:    string | null
  journal:        string | null
  year:           string | null
  url:            string | null
  core_claim:     string | null
  topic:          string | null
  episteme:       string | null
  techne:         string | null
  phronesis:      string | null
  relevance:      number | null
  citation_count?: number | null   // ORDER 122-fix: styr phronesis-plockning (Section C)
}
type PulseKw = { keyword: string; trend_direction: string; trend_pct: number }
type SavedMeta = { ids: string[]; topics: string[]; topTopic: string | null }

// ── HTTP-hjälpare ─────────────────────────────────────────────────────────
async function sbFetch(path: string, init: RequestInit = {}): Promise<Response> {
  return fetch(`${SB_URL}${path}`, {
    ...init,
    headers: {
      'apikey':        SB_KEY,
      'Authorization': `Bearer ${SB_KEY}`,
      'Content-Type':  'application/json',
      ...(init.headers as Record<string, string> || {}),
    },
  })
}
async function sbGet(path: string): Promise<any> {
  const r = await sbFetch(path)
  if (!r.ok) throw new Error(`sb ${r.status}: ${(await r.text()).slice(0,200)}`)
  return r.json()
}
async function sbRpc(name: string, params: object): Promise<any> {
  const r = await sbFetch(`/rest/v1/rpc/${name}`, {
    method: 'POST',
    body: JSON.stringify(params),
  })
  if (!r.ok) throw new Error(`rpc ${name} ${r.status}: ${(await r.text()).slice(0,200)}`)
  return r.json()
}

// ── HTML-escape ───────────────────────────────────────────────────────────
function esc(s: string | null | undefined): string {
  return String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!))
}

// ── Recipients ────────────────────────────────────────────────────────────
async function fetchRecipients(): Promise<Recipient[]> {
  // 6-day cutoff: last_digest_at is null eller <= now - interval '6 days'.
  // Kör mot profiles direkt med service_role. or=() PostgREST-syntax:
  //   last_digest_at.is.null,last_digest_at.lt.<cutoff>
  const cutoff = new Date(Date.now() - 6 * 86400_000).toISOString()
  const params = new URLSearchParams()
  params.append('select', 'id,email,display_name,role,is_pro,trial_ends_at,digest_token,last_digest_at')
  params.append('role', 'not.is.null')
  params.append('digest_enabled', 'is.true')
  params.append('or', `(last_digest_at.is.null,last_digest_at.lt.${cutoff})`)
  params.append('order', 'email')
  params.append('limit', '2000')  // pragmatiskt tak; utöka + paginera vid överskridande
  return await sbGet(`/rest/v1/profiles?${params.toString()}`)
}

function computeIsPro(r: Recipient): boolean {
  if (r.is_pro) return true
  if (r.trial_ends_at && new Date(r.trial_ends_at) > new Date()) return true
  return false
}

function computeSince(r: Recipient): Date {
  if (r.last_digest_at) return new Date(r.last_digest_at)
  return new Date(Date.now() - FALLBACK_SINCE_DAYS * 86400_000)
}

// ── User's saved metadata: ids, topics-aggregat, topTopic ─────────────────
async function fetchSavedMeta(uid: string): Promise<SavedMeta> {
  // Steg 1: fetch saved_articles(article_id, saved_at) för user
  const sel = new URLSearchParams()
  sel.append('select', 'article_id,saved_at')
  sel.append('user_id', `eq.${uid}`)
  sel.append('order', 'saved_at.desc')
  sel.append('limit', '500')
  const savedRows: {article_id: string; saved_at: string}[] = await sbGet(`/rest/v1/saved_articles?${sel.toString()}`)
  const ids = savedRows.map(s => s.article_id)
  if (!ids.length) return { ids: [], topics: [], topTopic: null }

  // Steg 2: fetch topic-fält för dessa ids från articles
  const inList = ids.map(id => `"${id}"`).join(',')
  const topicRows: {topic: string | null}[] = await sbGet(
    `/rest/v1/articles?select=topic&id=in.(${inList})&limit=500`
  )
  // Aggregera topics
  const counts: Record<string, number> = {}
  for (const r of topicRows) {
    if (r.topic) counts[r.topic] = (counts[r.topic] || 0) + 1
  }
  const sorted = Object.entries(counts).sort((a, b) => b[1] - a[1])
  const topics = sorted.map(([t]) => t)
  const topTopic = topics[0] || null
  return { ids, topics, topTopic }
}

// ── Section A: fem artiklar ───────────────────────────────────────────────
async function sectionA(r: Recipient, science: string, since: Date, topics: string[]): Promise<Article[]> {
  const sinceIso = since.toISOString()
  const params = new URLSearchParams()
  params.append('select',
    `id,title,headline_en,journal,year,url,core_claim,topic,citation_count,` +
    `episteme_${science},techne_${science},phronesis_${science},relevance_sci_${science}`
  )
  params.append('fetched_at', `gte.${sinceIso}`)
  params.append(`episteme_${science}`, 'not.is.null')
  params.append('irrelevant', 'not.is.true')
  if (topics.length) {
    params.append('topic', `in.(${topics.map(t => `"${t}"`).join(',')})`)
  }
  // ORDER 122-fix (item 2, Alt D): sekundär sort på year DESC gör att
  // nyare studier hamnar överst inom samma relevans-bucket. Ingen hård
  // årsfilter — landmark-oldies som just fått TRIAD ranker fortfarande
  // om relevansen är hög.
  params.append('order', `relevance_sci_${science}.desc.nullslast,year.desc.nullslast,fetched_at.desc`)
  params.append('limit', '5')
  const rows: any[] = await sbGet(`/rest/v1/articles?${params.toString()}`)
  return rows.map(a => ({
    id:             a.id,
    title:          a.title,
    headline_en:    a.headline_en,
    journal:        a.journal,
    year:           a.year,
    url:            a.url,
    core_claim:     a.core_claim,
    topic:          a.topic,
    episteme:       a[`episteme_${science}`],
    techne:         a[`techne_${science}`],
    phronesis:      a[`phronesis_${science}`],
    relevance:      a[`relevance_sci_${science}`],
    citation_count: a.citation_count ?? null,
  }))
}

// ORDER 122-fix: välj phronesis-källa till Section C EXKLUSIVT från
// articles[1..end]. Pro såg annars samma phronesis i toppartikelns
// TRIAD-block OCH i "This week's practical read" — dubblering. Free
// ser inget phronesis i korten men samma logik körs för konsistens.
//
// Rank inom articles.slice(1): citation_count DESC (signalerar canonical/
// diskuterad studie — semantiskt distinkt från relevance-rank). Stable
// sort bevarar relevance-ordning vid oavgjord citation_count. Måste ha
// phronesis-text för att kvalificera. Returnerar null om articles < 2
// eller ingen kandidat har phronesis-text (Section C skippas då).
function pickPhronesisArticle(articles: Article[]): Article | null {
  if (articles.length < 2) return null
  const candidates = articles.slice(1).filter(a => a.phronesis)
  if (!candidates.length) return null
  const sorted = [...candidates].sort(
    (a, b) => (b.citation_count ?? 0) - (a.citation_count ?? 0)
  )
  return sorted[0]
}

// ── Section B: research pulse (cache one gång per körning) ────────────────
async function sectionB(): Promise<PulseKw[]> {
  const data = await sbRpc('get_trending_keywords', { limit_n: 4 })
  return Array.isArray(data) ? data.slice(0, 4) : []
}

// ── Section F: rollens synthesis för mottagarens vanligaste topic ─────────
// Primär query: (role, topic) exakt match. Fallback: role only, senast
// uppdaterad. Om ingen match för rollen alls → null → sektionen skippas.
// Divergence-fältet läses INTE — alla 25 rader är convergence (2026-08-22)
// och fältet bär ingen information i nuläget.
type Synthesis = {
  title:         string
  synthesis:     string
  article_count: number
  ids_count:     number
  updated_at:    string
}
async function sectionF(scienceRole: string, topTopic: string | null): Promise<Synthesis | null> {
  const mapRow = (row: any): Synthesis => ({
    title:         row.title || '',
    synthesis:     row.synthesis || '',
    article_count: row.article_count ?? 0,
    ids_count:     Array.isArray(row.article_ids) ? row.article_ids.length : 0,
    updated_at:    row.updated_at,
  })
  // Primär: role + topTopic
  if (topTopic) {
    const p = new URLSearchParams()
    p.append('select', 'title,synthesis,article_count,article_ids,updated_at')
    p.append('role',   `eq.${scienceRole}`)
    p.append('topic',  `eq.${topTopic}`)
    p.append('limit',  '1')
    const rows: any[] = await sbGet(`/rest/v1/research_syntheses?${p.toString()}`)
    if (rows.length && (rows[0].synthesis || rows[0].title)) return mapRow(rows[0])
  }
  // Fallback: role only, senast uppdaterad
  const p = new URLSearchParams()
  p.append('select', 'title,synthesis,article_count,article_ids,updated_at')
  p.append('role',   `eq.${scienceRole}`)
  p.append('order',  'updated_at.desc')
  p.append('limit',  '1')
  const rows: any[] = await sbGet(`/rest/v1/research_syntheses?${p.toString()}`)
  if (rows.length && (rows[0].synthesis || rows[0].title)) return mapRow(rows[0])
  return null
}

// ── Section D: institution som publicerat mest inom user:s topTopic ───────
async function sectionD(topTopic: string | null): Promise<{name: string; count: number} | null> {
  if (!topTopic) return null
  const cutoff = new Date(Date.now() - 30 * 86400_000).toISOString()
  const params = new URLSearchParams()
  params.append('select', 'primary_institution')
  params.append('topic', `eq.${topTopic}`)
  params.append('fetched_at', `gte.${cutoff}`)
  params.append('primary_institution', 'not.is.null')
  params.append('limit', '500')
  const rows: {primary_institution: string}[] = await sbGet(`/rest/v1/articles?${params.toString()}`)
  if (!rows.length) return null
  // Aggregera i JS (PostgREST kan inte GROUP BY via URL)
  const counts: Record<string, number> = {}
  for (const r of rows) {
    counts[r.primary_institution] = (counts[r.primary_institution] || 0) + 1
  }
  const sorted = Object.entries(counts).sort((a, b) => b[1] - a[1])
  if (!sorted.length) return null
  return { name: sorted[0][0], count: sorted[0][1] }
}

// ── Section E: match_related seedad från user:s 3 senaste sparade ─────────
async function sectionE(seedIds: string[], excludeIds: Set<string>): Promise<Article[]> {
  if (!seedIds.length) return []
  const seeds = seedIds.slice(0, 3)
  const candidates: Map<string, {sim: number; row: any}> = new Map()

  for (const seedId of seeds) {
    try {
      // ORDER 122 (fix 2026-08-22): parameternamnen enligt migration
      // 20260731120000_articles_hnsw_match_related_grants.sql:
      // (p_article_id uuid, p_k int, p_floor float). Tidigare anrop med
      // match_count/similarity_threshold var fel — PGRST202 fångades tyst
      // av catch-blocket och Section E rapporterade konsekvent E0.
      //
      // p_floor 0.55 avviker från funktionens default 0.70 med avsikt:
      // 0.70 är en strikt tröskel för "in-app related research"-widgeten
      // (loadRelated i article-modal) där vi vill visa få men mycket
      // relevanta träffar. Veckobrevet är bredare i tonen — 0.55 matchar
      // ask-synth:s STRONG_SIM-tröskel och ger fler kandidater att välja
      // topp-2 från. Vid för många ovidkommande träffar kan tröskeln höjas.
      const rows = await sbRpc('match_related', {
        p_article_id: seedId,
        p_k:          5,
        p_floor:      0.55,
      })
      if (!Array.isArray(rows)) continue
      for (const row of rows) {
        if (!row?.id || excludeIds.has(row.id)) continue
        const prev = candidates.get(row.id)
        if (!prev || (row.similarity || 0) > prev.sim) {
          candidates.set(row.id, { sim: row.similarity || 0, row })
        }
      }
    } catch (e) {
      console.log(`[section-E] match_related failed for ${seedId}:`, (e as Error).message)
    }
  }
  const top = [...candidates.values()]
    .sort((a, b) => b.sim - a.sim)
    .slice(0, 2)
    .map(x => x.row)
  return top.map((a: any) => ({
    id:          a.id,
    title:       a.title,
    headline_en: null,
    journal:     a.journal || null,
    year:        a.year || null,
    url:         null,
    core_claim:  a.core_claim || null,
    topic:       null,
    episteme:    null,
    techne:      null,
    phronesis:   null,
    relevance:   null,
  }))
}

// ── HTML-byggnad ──────────────────────────────────────────────────────────
function articleCardHtml(a: Article, isPro: boolean): string {
  const title = a.headline_en || a.title
  const journal = a.journal ? esc(a.journal) : ''
  const year = a.year ? esc(a.year) : ''
  const meta = [journal, year].filter(Boolean).join(' · ')
  const paperLink = a.url
    ? `<a href="${esc(a.url)}" style="font-size:11px;color:#836428;text-decoration:none;border:1px solid rgba(160,138,85,.4);padding:4px 12px;border-radius:20px;display:inline-block;margin-top:6px">Read paper</a>`
    : ''
  const claim = a.core_claim
    ? `<p style="font-size:13px;color:#5C5649;line-height:1.7;margin:0 0 10px;font-style:italic">${esc(a.core_claim)}</p>`
    : ''
  const proBlock = isPro
    ? triadBlockHtml(a)
    : ''
  return `<div style="background:#fff;border:1px solid #E8E0D0;border-radius:10px;padding:20px;margin-bottom:14px">
    ${meta ? `<div style="font-size:11px;color:#9C9484;margin:0 0 6px">${meta}</div>` : ''}
    <h3 style="font-size:15px;font-weight:600;margin:0 0 8px;color:#0C0B09;line-height:1.4">${esc(title)}</h3>
    ${claim}
    ${proBlock}
    ${paperLink}
  </div>`
}

function triadBlockHtml(a: Article): string {
  const band = (label: string, marker: string, color: string, bg: string, text: string | null) => {
    if (!text) return ''
    return `<div style="margin:10px 0 0">
      <div style="font-size:10px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:${color};margin-bottom:4px">${marker}</div>
      <div style="font-size:12px;color:${color};line-height:1.6;padding:10px 12px;background:${bg};border-radius:6px">${esc(text)}</div>
    </div>`
  }
  return [
    band('episteme',  'ε Episteme',  '#1A3A5C', '#E8EFF6', a.episteme),
    band('techne',    'τ Techne',    '#2D5016', '#EAF0E5', a.techne),
    band('phronesis', 'φ Phronesis', '#5C2D00', '#F5EDE3', a.phronesis),
  ].join('')
}

function pulseHtml(pulse: PulseKw[]): string {
  if (!pulse.length) return ''
  const rows = pulse.map((k, i) => {
    const dir = k.trend_direction || 'stable'
    const label = dir === 'rising'    ? `↑ +${k.trend_pct}% vs 2024`
                : dir === 'declining' ? `↓ ${k.trend_pct}% vs 2024`
                : dir === 'new'       ? `✦ new 2025`
                :                       `→ stable`
    return `<tr>
      <td style="padding:6px 10px 6px 0;font-size:12px;color:#9C9484;width:24px">${i + 1}</td>
      <td style="padding:6px 10px 6px 0;font-size:13px;color:#0C0B09">${esc(k.keyword.replace(/_/g, ' '))}</td>
      <td style="padding:6px 0 6px 10px;font-size:11px;color:#5C5649;text-align:right">${label}</td>
    </tr>`
  }).join('')
  return `<div style="background:#fff;border:1px solid #E8E0D0;border-radius:10px;padding:16px 18px;margin-bottom:14px">
    <table style="width:100%;border-collapse:collapse">${rows}</table>
    <p style="font-size:10px;color:#9C9484;margin:12px 0 0;font-style:italic">Top-4 keywords in TRIAD-analysed articles · same across roles · 2025 vs 2024</p>
  </div>`
}

function phronesisHtml(text: string, sourceTitle: string, isPro: boolean): string {
  // ORDER 122-fix item 3 (Path B — märkt smakprov): Free ser phronesis
  // OCH en upsell-rad som använder ORDER 104:s fältrubriker för de andra
  // två läsningarna. Ingen TRIAD-modellförklaring. Pro ser ingen upsell.
  const upsell = !isPro ? `
    <div style="margin-top:14px;padding-top:12px;border-top:0.5px solid rgba(92,45,0,.22)">
      <p style="font-size:11.5px;color:#7A3D00;line-height:1.6;margin:0 0 10px">
        This is the third of three readings. The other two — what the research found, and what to do with it — come with Pro.
      </p>
      <a href="https://gusto.science" style="display:inline-block;font-size:11px;font-weight:600;color:#fff;background:#C9A84C;padding:6px 14px;border-radius:16px;text-decoration:none">Upgrade to Pro →</a>
    </div>` : ''
  // ORDER 124 item 2 (defensiv): humanize science-slug även i phronesis-
  // texten. Sonnet-prompten säger "for Sommelier/sensory scientist" så
  // slug-läckage är osannolik här, men samma helper — försumbar kostnad.
  return `<div style="background:#F5EDE3;border-left:3px solid #5C2D00;padding:16px 18px;margin-bottom:14px;border-radius:6px">
    <div style="font-size:13px;color:#5C2D00;line-height:1.7;margin:0 0 10px">${esc(humanizeRoleSlugs(text))}</div>
    <div style="font-size:10px;color:#7A3D00;font-style:italic">From: ${esc(sourceTitle)}</div>
    ${upsell}
  </div>`
}

function institutionHtml(inst: {name: string; count: number}, topicLabel: string): string {
  // ORDER 124 item 4 (Alt A): copyn är nu ärlig om vad topTopic är —
  // det är vanligaste ämnet i user:s saved_articles, inte roll-derivat.
  // Rubriken "Institution watch" står kvar; kroppen förklarar kopplingen.
  return `<div style="background:#fff;border:1px solid #E8E0D0;border-radius:10px;padding:16px 18px;margin-bottom:14px">
    <p style="font-size:13px;color:#0C0B09;margin:0;line-height:1.7">
      <strong>${esc(inst.name)}</strong> published ${inst.count} new
      ${inst.count === 1 ? 'study' : 'studies'} on
      <em>${esc(topicLabel)}</em> — a topic you've been saving.
    </p>
  </div>`
}

function savedRelatedHtml(articles: Article[]): string {
  if (!articles.length) return ''
  const rows = articles.map(a => {
    const title = a.headline_en || a.title
    const meta = [a.journal, a.year].filter(Boolean).join(' · ')
    return `<div style="padding:10px 0;border-bottom:0.5px solid #E8E0D0">
      ${meta ? `<div style="font-size:10px;color:#9C9484;margin:0 0 3px">${esc(meta)}</div>` : ''}
      <div style="font-size:13px;color:#0C0B09;line-height:1.5">${esc(title)}</div>
      ${a.core_claim ? `<div style="font-size:11px;color:#5C5649;font-style:italic;margin-top:4px;line-height:1.6">${esc(a.core_claim.slice(0, 180))}${a.core_claim.length > 180 ? '…' : ''}</div>` : ''}
    </div>`
  }).join('')
  return `<div style="background:#fff;border:1px solid #E8E0D0;border-radius:10px;padding:16px 18px;margin-bottom:14px">${rows}</div>`
}

// ── Section F HTML: rollens konvergerade läsning ─────────────────────────
// Kort card med title, synthesis-text, "Based on N studies"-metrik och
// länk till Syntheses-vyn. Ingen divergence (fältet bär ingen information
// idag — alla 25 rader är convergence).
function synthesisHtml(s: Synthesis): string {
  // ORDER 124 item 2: humanize science-slug före escape. Fixar de 25
  // befintliga raderna som har "For you as a culinary_pro" — rätt term
  // är "Chef" (samma etikett som brevets rubriker).
  const title = s.title ? esc(humanizeRoleSlugs(s.title)) : ''
  const body  = s.synthesis ? esc(humanizeRoleSlugs(s.synthesis)) : ''
  // "Based on N studies" — använd article_count som huvudsiffra. ids_count
  // kan skilja sig (t.ex. legacy 19 vs 10) men article_count är den
  // konsistenta siffran som edge-fn skriver.
  const n = s.article_count || s.ids_count
  const meta = n
    ? `Based on ${n} ${n === 1 ? 'study' : 'studies'} · <a href="https://gusto.science" style="color:#836428;text-decoration:none">Explore more →</a>`
    : `<a href="https://gusto.science" style="color:#836428;text-decoration:none">Explore more →</a>`
  return `<div style="background:#fff;border:1px solid #E8E0D0;border-radius:10px;padding:20px">
    ${title ? `<h3 style="font-size:15px;font-weight:600;margin:0 0 10px;color:#0C0B09;line-height:1.4">${title}</h3>` : ''}
    ${body ? `<p style="font-size:13px;color:#5C5649;line-height:1.7;margin:0 0 14px">${body}</p>` : ''}
    <div style="font-size:11px;color:#9C9484;margin:0">${meta}</div>
  </div>`
}

function sectionHeader(label: string): string {
  return `<h2 style="font-family:Georgia,serif;font-size:16px;font-weight:400;color:#0C0B09;margin:24px 0 12px;padding-bottom:8px;border-bottom:1px solid #E8E0D0">${esc(label)}</h2>`
}

type EmailData = {
  recipient: Recipient
  isPro: boolean
  roleLabel: string
  articles: Article[]
  pulse: PulseKw[]
  phronesisFrom: {text: string; title: string} | null
  institution: {name: string; count: number} | null
  institutionTopic: string | null
  savedRelated: Article[]
  synthesis: Synthesis | null   // ORDER 123 — Section F
}

// ORDER 122-fix item 1: bygg ingressen dynamiskt utifrån vilka sektioner
// som faktiskt renderas. Innan denna fix lovade brevet "what your saved
// library connects to" även när Section E var tom. Nämner bara B och E
// eftersom C och D är augmenteringar, inte huvudpelare — en TOC-rad i
// ingressen skulle ändå ha alla huvudsektioner nämnda och blir ointressant.
function introHtml(d: EmailData): string {
  const count = d.articles.length
  const study = count === 1 ? 'study' : 'studies'
  const base = `${count} newly analysed peer-reviewed ${study} for ${esc(d.roleLabel)}`
  const extras: string[] = []
  if (d.pulse.length)        extras.push("what's trending")
  if (d.savedRelated.length) extras.push('what your saved library connects to')
  const suffix = extras.length ? `, plus ${extras.join(' and ')}` : ''
  return `${base}${suffix}.`
}

function buildEmail(d: EmailData): string {
  const weekStr = new Date().toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' })
  const unsubUrl = `${UNSUB_BASE}?t=${encodeURIComponent(d.recipient.digest_token)}`
  // ORDER 124 item 3: fallback till "Hi," om display_name är för kort
  // eller ser ut som skräp (siffror/symboler). "Hi ds," ser sämre ut än
  // "Hi,". isValidGreetingName kräver ≥2 tecken efter trim + minst en
  // bokstav (unicode-aware).
  const greeting = isValidGreetingName(d.recipient.display_name)
    ? `Hi ${esc(d.recipient.display_name!.trim())},`
    : `Hi,`

  const sections: string[] = []

  // A. Fem artiklar (ORDER 122-fix item 2: rubriken speglar att detta är
  // artiklar som fetchats/analyserats nyligen — INTE artiklar publicerade
  // nyligen. En 1994-studie som just fått TRIAD är "nyanalyserad", inte "ny").
  sections.push(sectionHeader(`Newly analysed for ${d.roleLabel}`))
  sections.push(d.articles.map(a => articleCardHtml(a, d.isPro)).join(''))

  // B. Research Pulse
  if (d.pulse.length) {
    sections.push(sectionHeader('Research Pulse'))
    sections.push(pulseHtml(d.pulse))
  }

  // C. Veckans omdöme (ORDER 122-fix item 3: isPro-flag styr upsell)
  if (d.phronesisFrom) {
    sections.push(sectionHeader("This week's practical read"))
    sections.push(phronesisHtml(d.phronesisFrom.text, d.phronesisFrom.title, d.isPro))
  }

  // D. Institutionsobservation
  if (d.institution && d.institutionTopic) {
    sections.push(sectionHeader('Institution watch'))
    sections.push(institutionHtml(d.institution, d.institutionTopic.replace(/_/g, ' ')))
  }

  // E. Sparat-påminnelse
  if (d.savedRelated.length) {
    sections.push(sectionHeader('Related to what you\'ve saved'))
    sections.push(savedRelatedHtml(d.savedRelated))
  }

  // F. Rollens konvergerade läsning (ORDER 123). Rubrik "Where the field
  // aligns" — inte "Synthesis". Speglar current state där alla 25
  // research_syntheses-rader är evidence_type=convergence. Divergence
  // används inte (fältet bär ingen information idag). Toleras tom via
  // if(d.synthesis)-guarden — samma mönster som C/D/E.
  if (d.synthesis) {
    sections.push(sectionHeader('Where the field aligns'))
    sections.push(synthesisHtml(d.synthesis))
  }

  const tierBadge = d.isPro
    ? '<span style="font-size:10px;color:#C9A84C">Pro</span>'
    : ''

  return `<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Gusto Weekly</title></head>
<body style="margin:0;padding:0;background:#F7F4ED;font-family:'Outfit',system-ui,-apple-system,sans-serif;color:#0C0B09">
<div style="max-width:620px;margin:0 auto;padding:24px 16px">
  <div style="text-align:center;padding:24px 0 16px">
    <h1 style="font-size:26px;font-weight:400;color:#0C0B09;margin:0 0 4px;font-family:Georgia,serif">Gusto Science</h1>
    <p style="font-size:12px;color:#9C9484;margin:0">Weekly research digest · ${esc(weekStr)} ${tierBadge}</p>
  </div>
  <p style="font-size:14px;color:#0C0B09;margin:0 0 16px">${greeting}</p>
  <p style="font-size:14px;color:#5C5649;line-height:1.7;margin:0 0 20px">${introHtml(d)}</p>
  ${sections.join('')}
  <div style="text-align:center;padding:28px 0 12px;border-top:1px solid #E8E0D0;margin-top:32px">
    <p style="font-size:11px;color:#9C9484;margin:0 0 6px">Gusto Science · Dr Anders Crichton-Fock</p>
    <p style="font-size:11px;color:#9C9484;margin:0">
      <a href="${esc(unsubUrl)}" style="color:#9C9484">Unsubscribe from the weekly digest</a>
    </p>
  </div>
</div>
</body></html>`
}

// ── Brevo send ────────────────────────────────────────────────────────────
async function sendMail(to: {email: string; name: string | null}, subject: string, html: string): Promise<{ok: boolean; detail: string}> {
  try {
    const resp = await fetch('https://api.brevo.com/v3/smtp/email', {
      method: 'POST',
      headers: { 'api-key': BREVO_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        sender:      { email: SENDER_EMAIL, name: SENDER_NAME },
        to:          [{ email: to.email, name: to.name || undefined }],
        subject,
        htmlContent: html,
      }),
    })
    if (!resp.ok) {
      const txt = await resp.text().catch(() => '')
      return { ok: false, detail: `brevo ${resp.status}: ${txt.slice(0, 200)}` }
    }
    return { ok: true, detail: 'sent' }
  } catch (e) {
    return { ok: false, detail: `network: ${(e as Error).message}` }
  }
}

async function markSent(uid: string): Promise<boolean> {
  const r = await sbFetch(`/rest/v1/profiles?id=eq.${uid}`, {
    method: 'PATCH',
    headers: { 'Prefer': 'return=minimal' },
    body: JSON.stringify({ last_digest_at: new Date().toISOString() }),
  })
  return r.ok
}

// ── Main ──────────────────────────────────────────────────────────────────
async function main() {
  const startedAt = new Date().toISOString()
  console.log(`[start] mode=${APPLY ? 'APPLY (skickar)' : 'DRY-RUN'}  at=${startedAt}`)

  const recipients = await fetchRecipients()
  console.log(`[fetch] ${recipients.length} mottagare (role satt, digest_enabled, cooldown passerad)`)

  if (!recipients.length) {
    console.log('[done] inga mottagare — inget att göra')
    return
  }

  // Section B cacheas — samma pulse för alla mottagare
  let pulse: PulseKw[] = []
  try { pulse = await sectionB() }
  catch (e) { console.log('[section-B] failed:', (e as Error).message) }
  console.log(`[cache] pulse: ${pulse.length} keywords`)

  if (!APPLY) {
    await Deno.mkdir(OUT_DIR, { recursive: true }).catch(() => {})
  }

  const counters = {
    sent: 0, would_send: 0, skipped_no_articles: 0, failed: 0,
  }

  for (const r of recipients) {
    const science = ROLE_TO_SCIENCE[r.role]
    if (!science) {
      console.log(`  [skip] ${r.email}: unknown role "${r.role}"`)
      continue
    }
    const isPro     = computeIsPro(r)
    const since     = computeSince(r)
    const roleLabel = ROLE_LABEL[r.role]

    try {
      const savedMeta   = await fetchSavedMeta(r.id)
      const topicFilter = savedMeta.ids.length >= 3 ? savedMeta.topics.slice(0, 2) : []
      const articles    = await sectionA(r, science, since, topicFilter)

      if (!articles.length) {
        counters.skipped_no_articles++
        console.log(`  [skip] ${r.email} (${r.role}): 0 nya artiklar sedan ${since.toISOString().slice(0,10)}`)
        continue
      }

      // Section C: phronesis-text från en ANNAN artikel än articles[0]
      // (den syns redan i toppkortets TRIAD-block för Pro). Väljs via
      // pickPhronesisArticle: högst citation_count bland artikel 2-5.
      // Returnerar null om articles < 2 eller ingen kandidat har phronesis.
      const phronesisArt  = pickPhronesisArticle(articles)
      const phronesisFrom = phronesisArt
        ? { text: phronesisArt.phronesis!, title: phronesisArt.headline_en || phronesisArt.title }
        : null

      // Section D: institution för user:s topTopic
      let institution: {name: string; count: number} | null = null
      try { institution = await sectionD(savedMeta.topTopic) }
      catch (e) { console.log(`  [section-D] ${r.email}: ${(e as Error).message}`) }

      // Section E: match_related från 3 senaste sparade
      const excludeIds = new Set(savedMeta.ids)
      const savedRelated = await sectionE(savedMeta.ids.slice(0, 3), excludeIds)

      // Section F (ORDER 123): rollens synthesis för mottagarens vanligaste
      // topic. Faller tillbaka på rollens senast uppdaterade om topTopic
      // saknas eller ingen (role, topic)-match finns. Skippas i buildEmail
      // om null (samma tolerans som C/D/E).
      let synthesis: Synthesis | null = null
      try { synthesis = await sectionF(science, savedMeta.topTopic) }
      catch (e) { console.log(`  [section-F] ${r.email}: ${(e as Error).message}`) }

      const emailData: EmailData = {
        recipient: r, isPro, roleLabel, articles, pulse,
        phronesisFrom, institution, institutionTopic: savedMeta.topTopic,
        savedRelated, synthesis,
      }
      const html    = buildEmail(emailData)
      // ORDER 122-fix item 2: subject speglar rubriken — "newly analysed"
      // istället för "new" (som implicerar recently published).
      const subject = `Gusto Weekly — ${articles.length} newly analysed for ${roleLabel}`

      if (APPLY) {
        const send = await sendMail({ email: r.email, name: r.display_name }, subject, html)
        if (send.ok) {
          const marked = await markSent(r.id)
          if (marked) {
            counters.sent++
            console.log(`  [sent] ${r.email} (${r.role}) · ${isPro ? 'Pro' : 'Free'} · A${articles.length} B${pulse.length} C${phronesisFrom ? 1 : 0} D${institution ? 1 : 0} E${savedRelated.length} F${synthesis ? 1 : 0}`)
          } else {
            counters.failed++
            console.log(`  [warn] ${r.email}: mail sent men last_digest_at kunde inte uppdateras — nästa run skickar igen`)
          }
        } else {
          counters.failed++
          console.log(`  [fail] ${r.email}: ${send.detail}`)
        }
        await new Promise(res => setTimeout(res, PER_SEND_MS))
      } else {
        const safeName = r.email.replace(/[^\w.-]/g, '_')
        await Deno.writeTextFile(`${OUT_DIR}/${safeName}.html`, html)
        counters.would_send++
        console.log(`  [preview] ${r.email} (${r.role}) · ${isPro ? 'Pro' : 'Free'} · A${articles.length} B${pulse.length} C${phronesisFrom ? 1 : 0} D${institution ? 1 : 0} E${savedRelated.length} F${synthesis ? 1 : 0}`)
      }
    } catch (e) {
      counters.failed++
      console.log(`  [error] ${r.email}: ${(e as Error).message}`)
    }
  }

  const finishedAt = new Date().toISOString()
  console.log(`\n[done] mode=${APPLY ? 'APPLY' : 'DRY-RUN'}  ${finishedAt}`)
  if (APPLY) {
    console.log(`  sent=${counters.sent}  failed=${counters.failed}  skipped_no_articles=${counters.skipped_no_articles}`)
  } else {
    console.log(`  would_send=${counters.would_send}  failed=${counters.failed}  skipped_no_articles=${counters.skipped_no_articles}`)
    console.log(`  preview HTML: ${OUT_DIR}/<email>.html`)
  }
}

main().catch(e => { console.error('[FATAL]', e); Deno.exit(1) })
