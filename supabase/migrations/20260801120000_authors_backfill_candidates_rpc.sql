-- =============================================================================
-- authors_backfill_candidates — kandidater för Scopus-author-backfill
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE VIA `supabase db push`.
-- Följer samma mönster som 20260725120000_match_related.sql: fresh replay
-- från början är trasig pga chip-kolumn-refs i content_gating; filen finns
-- för git-paritet.
--
-- BAKGRUND:
--
--   scripts/backfill-authors-openalex.ts försökte fånga målpopulationen
--   (source='scopus' + singelnamn + doi.org-url) direkt via PostgREST:
--     source=eq.scopus & authors=not.is.null
--     & authors=not.ilike.*,*  ← kommat i mönstret tolkas som arg-sep
--     & url=ilike.*doi.org/*
--
--   PostgREST släppte authors-not.ilike-filtret tyst → populationen blev
--   HELA articles-tabellen (236 174 rader innan statement_timeout).
--   Målpopulationen är ~13 540. Silent drop av ett filter i en backfill
--   som skriver till DB är oacceptabel risk.
--
--   Lösning: flytta filterlogiken till SQL i en RPC. Deterministisk,
--   version-oberoende av PostgREST-tolkning, och matchar mönstret från
--   triad_background_candidates / fetch_backfill_haiku_batch.
--
-- KONTRAKT:
--
--   - order by id → stabil paginering + idempotent återupptagning
--     (efter lyckad PATCH innehåller authors komma → filtreras bort)
--   - stable language sql, invoker-rätt (backfill kör som service_role
--     som bypasser RLS ändå)
--   - grant execute till service_role only — inte anon/authenticated,
--     detta är en admin-operation
--
-- TRIAD-VILLKORET (episteme_sensory_pro is not null):
--
--   Utan denna rad returnerade RPC:n 304 623 rader — 22× målpopulationen.
--   Skillnaden är råa Scopus-rader som ligger i articles men aldrig
--   passerat TRIAD-pipelinen. De är inte synliga i Feed/overlay, ingen
--   användare kan citera dem, ingen kommer se den trunkerade författar-
--   listan. Att backfilla dem hade förbrukat 22× OpenAlex-quota utan
--   epistemisk vinst.
--
--   episteme_sensory_pro (bool/text på articles) sätts av TRIAD-analysen
--   → not null = "har gått igenom labeled-triad" = "kan bli citerad".
--   Det är EXAKT den populationen där truncerade authors ger fel APA-ref
--   i produkten. Beräknat mot prod 2026-08-01: 13 540 rader — matchar
--   det ursprungliga stickprovet på scripts/stickprov-author-parity.ts.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.authors_backfill_candidates(p_limit int)
RETURNS TABLE(id uuid, url text, authors text)
LANGUAGE sql
STABLE
AS $function$
  select id, url, authors
  from public.articles
  where source = 'scopus'
    and authors is not null
    and authors not like '%,%'
    and url like '%doi.org/%'
    and episteme_sensory_pro is not null
  order by id
  limit p_limit
$function$;

revoke all on function public.authors_backfill_candidates(int) from public, anon, authenticated;
grant execute on function public.authors_backfill_candidates(int) to service_role;


-- =============================================================================
-- Verifiering (efter apply):
--
--   -- Snabbcheck att RPC:n returnerar förväntad storleksordning (~13 540):
--   select count(*) from public.authors_backfill_candidates(50000);
--   -- expected: ~13 540 (aug 2026-baseline; går ner efter varje backfill-batch)
--
--   -- Grants:
--   select has_function_privilege('anon',
--     'public.authors_backfill_candidates(int)', 'EXECUTE');   -- expect false
--   select has_function_privilege('authenticated',
--     'public.authors_backfill_candidates(int)', 'EXECUTE');   -- expect false
--   select has_function_privilege('service_role',
--     'public.authors_backfill_candidates(int)', 'EXECUTE');   -- expect true
-- =============================================================================
