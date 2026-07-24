import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { buildEmbeddingText, EMBEDDING_COLUMNS, TEXT_SLICE, type EmbeddingSource } from '../_shared/embedding-text.ts'

type QueueRow = EmbeddingSource & { id: string }

const OPENAI_KEY = Deno.env.get('OPENAI_API_KEY')
const SB_URL = Deno.env.get('SUPABASE_URL')
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')

const DEFAULT_BATCH = 300         // avg 3.6k chars/artikel → 269k tokens (avg), säker mot 300k cap
const HARD_TOKENS = 275000        // runtime-tak; om texts[] estimerar över, avvisa
const DB_UPDATE_CONCURRENCY = 20  // parallella per-rad-updates

Deno.serve(async (req) => {
  const startedAt = Date.now()
  const supabase = createClient(SB_URL!, SB_KEY!)

  const body = req.method === 'POST' ? await req.json().catch(() => ({})) : {}
  const batchSize = Math.max(1, Math.min(500, Number(body.batch_size) || DEFAULT_BATCH))
  console.log(`1: start batch_size=${batchSize}`)

  const { data: articles, error } = await supabase
    .from('articles')
    .select(EMBEDDING_COLUMNS.join(','))
    .not('episteme_sensory_pro', 'is', null)
    .is('embedding', null)
    .limit(batchSize)
    .returns<QueueRow[]>()
  console.log(`2: fetched ${articles?.length ?? 0}${error ? ` error=${error.message}` : ''}`)

  if (error || !articles?.length) {
    return json({
      ok: true, processed: 0, batch_size: batchSize,
      duration_ms: Date.now() - startedAt,
      note: articles ? 'queue empty' : (error?.message || 'select failed')
    })
  }

  // Bygg texts[] och PACKA tills taket. Skicka det som ryms — resten
  // (articles[packedTo..end]) hämtas nästa cron-tick. Aldrig 0 processed
  // pga batch-full — kön rör sig alltid framåt.
  //
  // Invariant: SELECT filtret ".not('episteme_sensory_pro','is',null)"
  // garanterar minst episteme_sensory_pro-fältet är satt. Verifierat mot
  // DB 2026-07-12: 0 av 9 193 rader har empty string. Pipeline (labeled-
  // triad.ts) skriver endast fält som passerat validateTriad (min 180
  // tecken per roll-fält). t kan alltså aldrig bli tom — vi behöver inte
  // (och får inte) hoppa över den, eftersom det skulle skapa en tyst
  // queue-loop.
  const est = (s: string) => Math.ceil(s.length / 4)
  const texts: string[] = []
  const packedIds: string[] = []
  const hardTruncated: string[] = []   // artiklar där en enskild text > HARD_TOKENS
  let sum = 0
  let packedTo = 0

  for (let i = 0; i < articles.length; i++) {
    const a = articles[i]
    let t = buildEmbeddingText(a)

    // Patologisk artikel: >HARD_TOKENS ensam. Hård-kapa så kön inte fastnar
    // för alltid. Kan inte inträffa med TEXT_SLICE=8000 (max ~2000 tokens)
    // men koden överlever framtida config-ändringar.
    if (est(t) > HARD_TOKENS) {
      const cap = Math.floor(HARD_TOKENS * 4 * 0.9)
      t = t.slice(0, cap)
      hardTruncated.push(a.id.slice(0, 8))
      console.log(`Hard-truncated oversize article ${a.id.slice(0,8)}`)
    }

    const rowTokens = est(t)
    if (sum + rowTokens > HARD_TOKENS) {
      break  // resten (articles[i..end]) väntar till nästa tick
    }

    texts.push(t)
    packedIds.push(a.id)
    sum += rowTokens
    packedTo = i + 1
  }

  const estTokens = sum
  console.log(`3: packed ${texts.length} tokens ${sum} deferred ${articles.length - packedTo}`)

  // Om vi inte packade en enda artikel: raden ensam >HARD_TOKENS (kunde inte
  // ens kapas — omöjligt eftersom cap är 90% av taket). Bara ett bör-ej-hända
  // säkerhetsnät.
  if (!texts.length) {
    return json({
      ok: false,
      error: 'packed 0 articles — first article exceeded HARD_TOKENS even after truncation',
      fetched: articles.length,
      batch_size: batchSize,
      duration_ms: Date.now() - startedAt
    }, 500)
  }

  // ETT batch-anrop mot OpenAI /v1/embeddings med input: string[].
  // AbortController 60s: Deno fetch har ingen default-timeout. Ett
  // hängt anrop skulle annars äta hela edge-fn:ens wall-clock utan
  // signal (200s tyst 2026-07-14 var symptom på just detta).
  const openaiStart = Date.now()
  const openaiAc = new AbortController()
  const openaiTimer = setTimeout(() => openaiAc.abort(), 60_000)
  let res: Response
  try {
    res = await fetch('https://api.openai.com/v1/embeddings', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${OPENAI_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: 'text-embedding-3-small', input: texts }),
      signal: openaiAc.signal
    })
  } catch (e) {
    clearTimeout(openaiTimer)
    const aborted = (e as Error).name === 'AbortError'
    console.log(`ABORT: openai ${aborted ? 'timeout-60s' : (e as Error).name}`)
    return json({
      ok: false,
      error: aborted ? 'openai timeout after 60s' : (e as Error).message,
      packed: texts.length, est_tokens: estTokens,
      openai_ms: Date.now() - openaiStart,
      duration_ms: Date.now() - startedAt
    }, aborted ? 504 : 502)
  }
  clearTimeout(openaiTimer)
  const openaiMs = Date.now() - openaiStart

  const rateLimits: Record<string, string> = {}
  for (const k of ['x-ratelimit-limit-requests','x-ratelimit-limit-tokens','x-ratelimit-remaining-requests','x-ratelimit-remaining-tokens','x-ratelimit-reset-requests','x-ratelimit-reset-tokens']) {
    const v = res.headers.get(k); if (v) rateLimits[k] = v
  }

  if (!res.ok) {
    const errBody = (await res.text()).slice(0, 400)
    return json({
      ok: false, error: `openai ${res.status}`, body: errBody,
      openai_rate_limit: rateLimits, openai_ms: openaiMs,
      batch_size: batchSize, fetched: articles.length, est_tokens: estTokens,
      duration_ms: Date.now() - startedAt
    }, 502)
  }

  const d = await res.json()
  const embeddings: Array<{ index?: number, embedding: number[] }> = d.data || []
  console.log(`4: openai done ${embeddings.length} vectors in ${openaiMs}ms`)

  // KRITISKT: verifiera length. Skriv ALDRIG halva batchen.
  if (embeddings.length !== texts.length) {
    return json({
      ok: false,
      error: `openai returned ${embeddings.length} embeddings for ${texts.length} inputs`,
      openai_rate_limit: rateLimits, openai_ms: openaiMs,
      duration_ms: Date.now() - startedAt
    }, 502)
  }

  // Mappa tillbaka till articles[i]. OpenAI-svaret är sorterat på index (per spec)
  // — men verifiera via index-fältet defensivt så en osorterad respons inte
  // korrumperar mappningen.
  const rows: Array<{ id: string, embedding: number[] }> = []
  for (let i = 0; i < texts.length; i++) {
    const e = embeddings.find(x => x.index === i) ?? embeddings[i]
    if (!e || !Array.isArray(e.embedding)) {
      return json({
        ok: false,
        error: `missing embedding for index ${i}`,
        openai_rate_limit: rateLimits, openai_ms: openaiMs,
        duration_ms: Date.now() - startedAt
      }, 502)
    }
    rows.push({ id: packedIds[i], embedding: e.embedding })
  }

  // Uppdatera DB parallellt i chunks. Enskilda .update-anrop per rad
  // eftersom .upsert med bara {id, embedding} bryter mot NOT NULL på övriga
  // articles-kolumner (INSERT-grenen bakom ON CONFLICT). Parallellism 20
  // håller Supabase-connections rimliga.
  const dbStart = Date.now()
  let dbOk = 0, dbErr = 0
  let firstDbError: string | null = null
  for (let i = 0; i < rows.length; i += DB_UPDATE_CONCURRENCY) {
    const chunk = rows.slice(i, i + DB_UPDATE_CONCURRENCY)
    const results = await Promise.all(
      chunk.map(r => supabase.from('articles').update({ embedding: r.embedding }).eq('id', r.id))
    )
    for (const r of results) {
      if (r.error) {
        dbErr++
        if (firstDbError === null) firstDbError = r.error.message
      } else {
        dbOk++
      }
    }
  }
  const dbMs = Date.now() - dbStart
  console.log(`5: written ${dbOk} errors ${dbErr} in ${dbMs}ms`)

  return json({
    ok: dbErr === 0,
    processed: dbOk,                                 // rader skrivna till DB
    packed: texts.length,                             // rader skickade till OpenAI
    fetched: articles.length,                         // rader hämtade ur kön
    deferred: articles.length - packedTo,             // rader som väntar till nästa tick
    hard_truncated: hardTruncated,                    // artikel-id-prefix som kapades hårt
    db_errors: dbErr,
    first_db_error: firstDbError,
    batch_size: batchSize,
    est_tokens: estTokens,
    openai_ms: openaiMs,
    db_update_ms: dbMs,
    duration_ms: Date.now() - startedAt,
    openai_rate_limit: rateLimits
  })
})

function json(body: any, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { 'Content-Type': 'application/json' }
  })
}
