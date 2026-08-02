# PostgREST-tak i det här projektet

## db-max-rows = 1000 — server-side, tyst

Verifierat 2026-08-02:

```js
await sb.from('articles_public')
  .select('id,primary_institution,country')
  .eq('irrelevant', false)
  .limit(30000)
// → data: Array(1000), status: 200, error: null
```

**Servern kapar tyst vid 1 000 rader oavsett vad klienten begär.** Ingen
error, ingen `Content-Range`-varning som är trivial att missa, inga
loggade tecken på att capet triggades. En client-side check mot
`response.length === MY_LIMIT` triggar aldrig när `MY_LIMIT > 1000`.

Tre incidenter i vecka 31–32 2026 spårade till detta:

1. **Author-backfill (2026-08-01):** PostgREST tolkade kommat i
   `authors=not.ilike.*,*` som argumentavgränsare, släppte filtret tyst,
   och drog 236 174 rader (hela biblioteket) mot förväntade 13 540.
   Symptom: query lyckades. Löst genom att flytta filterlogiken till en
   SQL RPC. Se `20260801120000_authors_backfill_candidates_rpc.sql`.

2. **Author-backfill live-körning (2026-08-01):** samma script ovan i
   skarpa läge — populations-batchen kapade vid 1 000 första körningen.
   Löst genom yttre paginationsloop över RPC-anropen.

3. **Map-vyn (2026-08-02):** client-side aggregering över 38 897 non-
   irrelevant articles var omöjlig; PostgREST returnerade 1 000 av dem,
   Sverige gick från 10 dots till 1. Löst genom två aggregerings-RPC:er
   som returnerar JSONB (en rad — bypass av per-row-cappet). Se
   `20260802140000_map_stats_rpcs.sql`.

## Regel

**Om en client-side operation kräver mer än 1 000 rader → antingen:**

- **Aggregera i SQL via RPC.** Returnera JSONB (`jsonb_agg(...)`), en enda
  rad — då gäller inte per-row-cappet på svaret. Detta är default för alla
  count/sum/group-operationer.
- **Paginera explicit** via `limit=1000&offset=N` i loop, med break när
  batchen är kortare än pageSize. Bara när klienten faktiskt behöver alla
  rader.
- **Aldrig** förlita sig på ett `limit=X` (X > 1000) och anta att servern
  respekterar det — den ignorerar tyst.

## Skydd

En `console.warn(...)` i klientkoden mot `response.length === LIMIT`
fungerar bara om `LIMIT ≤ 1000`. För större värden är den värdelös —
kapet händer före klienten ser något. Fånga i stället:

```js
if (response.length === 1000 && WE_EXPECTED_MORE) {
  console.warn('POSTGREST_CAP hit — paginate or RPC-aggregate')
}
```

...eller bättre: bygg om till RPC direkt när populationen kan växa förbi
1 000.

## Prefer: count=exact

**Undantag:** `Content-Range`-headern från `Prefer: count=exact` returnerar
den faktiska count(*), inte den kapade rad-mängden. Det gör HEAD-count-
queries säkra (används för coverage-copyn i map-vyn). Men verifiera vid
tveksamhet — testa mot en känd population.

## `db-max-rows` som setting

Cappet är en PostgREST-konfiguration i Supabase-projektet. Det går teoretiskt
att höja, men (a) det är en global inställning som påverkar alla queries
och kan blåsa upp payload/timeout-risker, och (b) det ligger utanför git
och kan ändras oavsiktligt vid infrastrukturarbete. **Bygg som om cappet
alltid är 1 000** — då är applikationen robust oavsett vad settingen är.
