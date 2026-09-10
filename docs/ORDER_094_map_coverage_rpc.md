# ORDER 094 — Server-side RPC för map coverage. AUTONOM.

Repo: gastro-research. Ny gren från main.
Fortsättning på ORDER 093 §4-rapport.

## §0 Läget

Kartvyns coverage-copy visar `Institution coordinates: unavailable`.
Diagnos-loggen från ORDER 093 §2.3 avslöjade orsaken:

    [coverage-copy] countOf null {"label":"total","status":500,...}

Två parallella `Prefer: count=exact`-fetches mot `articles_public` från
browsern får 500 från PostgREST. Predikatet har fem-vägs `has_episteme_
<role>` OR + `irrelevant=false` + `primary_institution not null` över
466 905 rader, dubbelt scannade — hit statement_timeout eller
räknar-cap. Direkt `curl` för samma URL ensam fungerar.

Fix: en RPC som räknar båda talen server-side i en enda tabellskanning,
följer `triad_coverage()`-mönstret från ORDER 091 §6.

## §1 RPC-specifikation

**Signatur:**

```sql
CREATE OR REPLACE FUNCTION public.map_coverage()
RETURNS jsonb
```

**Varför jsonb, inte TABLE:** matchar `triad_coverage()`:s enkel-parse-
pattern (`await r.json()` → objekt direkt, ingen array-unwrap). TABLE
returnerar array från PostgREST vilket kräver `data[0]?.field` — mer
felkällor för samma information.

**Returvärde:** `{"with_coords": bigint, "total": bigint}`.

**Predikatet är identiskt med dagens `updateMapCoverageCopy`**
(rad ~6170–6171 i index.html):

```
irrelevant = false
  AND primary_institution IS NOT NULL
  AND (has_episteme_sensory_pro
       OR has_episteme_culinary_pro
       OR has_episteme_gastronomy_culture
       OR has_episteme_hospitality_mgmt
       OR has_episteme_educator_researcher)
```

**Räknar båda talen i en tabellskanning** med
`count(*) FILTER (WHERE …)`:

```sql
SELECT jsonb_build_object(
  'with_coords', count(*) FILTER (
    WHERE institution_coords IS NOT NULL
      AND jsonb_array_length(institution_coords) > 0
  ),
  'total',       count(*)
)
FROM public.articles
WHERE irrelevant = false
  AND primary_institution IS NOT NULL
  AND (phronesis_sensory_pro         IS NOT NULL
    OR phronesis_culinary_pro        IS NOT NULL
    OR phronesis_gastronomy_culture  IS NOT NULL
    OR phronesis_hospitality_mgmt    IS NOT NULL
    OR phronesis_educator_researcher IS NOT NULL);
```

**Notera:** predikatet i `updateMapCoverageCopy` läser från vyn
`articles_public` som exponerar `has_episteme_<role>` som booleans.
RPC:n läser direkt från `public.articles` — där `has_episteme_<role>`
inte finns som kolumner. Använd `phronesis_<role> IS NOT NULL` (canary-
fältet, ORDER 091 §6). Sätter samma set (TRIAD-pipelinen skriver
ε/τ/φ atomärt per roll — has_episteme_X ⇔ phronesis_X is not null).

För `articles_public` gäller dessutom `irrelevant is not true`, matcha
med `irrelevant = false` mot `articles`. (Om DB har `irrelevant is null`-
artiklar kommer talen skilja. Verifiera mot §3.)

**Boilerplate — kopiera från `triad_coverage()`:**

- `LANGUAGE sql`
- `STABLE`
- `SECURITY DEFINER`
- `SET search_path = public, pg_temp`
- `SET statement_timeout = '30s'`
- `GRANT EXECUTE ... TO anon, authenticated, service_role`

**Verifiering:**

```sql
select public.map_coverage();
```

Förväntat: `{"with_coords": 20283, "total": 28553}` — ± några dagar av
nya artiklar. Om talen skiljer i storleksordning: fel predikat.

## §2 index.html-parsning i samma commit

`updateMapCoverageCopy` (rad ~6159–6208) skrivs om:

- Ta bort `countOf`-helpern och `Promise.all([countOf(...), countOf(...)])`
- Ersätt med ETT anrop till `/rest/v1/rpc/map_coverage`
- Parse: `const {with_coords, total} = await r.json()`
- Behåll diagnos-loggen från ORDER 093 §2.3 (nu logga `{status, ok, type, value}` som `triad_coverage`-mönstret)
- Behåll `unavailable`-fallback vid null/fel
- Behåll copyn OFÖRÄNDRAD: "N of M TRIAD-analysed articles with known
  institution — backfilling ongoing."
- Behåll `#dp-map-coverage`-skrivningen (data-panelen)

Rör inte `initWorldMap`:s fire-and-forget-anrop (ORDER 093 §2.2) —
det håller.

## §3 Krav

- Migration lagd i `supabase/migrations/20260818150000_map_coverage_rpc.sql`
  (eller senare timestamp om det redan finns filer på den tiden).
  Kör manuellt i SQL-editorn — INTE via `supabase db push` (skulle
  försöka köra om augusti-migrationerna). Notera detta i migrationens
  header.
- Commit per paragraf: en för migration, en för index.html-wireup.
- Push branch, merge till main när båda commits ligger, push main.
- När Anders kört migrationen: verifiera med headless-Chrome
  screenshot av `/?view=map` att copyn skrivs korrekt utan manuellt
  re-anrop.

## §4 Rapport

- Migrationens slutliga SQL i sin helhet (kodblock, redo att klistra in)
- Verifieringsfrågan + förväntat tal
- Vilka rader i index.html du bytte
- Screenshot av copyn efter att migrationen körts
- Om verifieringstalet skiljer från 20 283 / 28 553: förklara varför
  (troligen `irrelevant is null` vs `irrelevant is not true`, se §1)

Push. Ingen merge till main förrän migrationen är körd och verifierad —
annars deployar vi frontend som anropar en RPC som inte finns → tyst
`unavailable` fortsätter. Undantag: om du landar migration-filen i main
tillsammans med frontend-fixen och Anders lovar köra SQL:en direkt.
Anta det senare — Anders är på och kör.
