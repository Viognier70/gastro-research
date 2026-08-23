-- =============================================================================
-- ORDER 142 — get_sidebar_stats tappar topics-branchen (dead field)
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- BAKGRUND (2026-08-24):
--
--   Efter ORDER 140 (levande topic-counts i Feed-toolbaren) och ORDER 141
--   (get_sidebar_stats.topics filtrerade nu irrelevant) var sidopanelens
--   "Top topics"-tag-cloud funktionellt REDUNDANT med toolbarens topic-
--   select — samma data, samma siffror, samma filtrering. ORDER 142 tar
--   bort sidopanels-sektionen (HTML + loadSidebar-JS) och denna migration
--   städar bort dead RPC-fältet.
--
-- MOTIV FÖR ATT TA BORT RPC-fältet:
--   * Cost efter ORDER 141: ~5-20 ms per anrop. Billigt men inte gratis.
--   * Dead API-fält göms lätt — någon läser response senare, ser
--     'topics'-nyckel, undrar vad den ska vara till för. Explicit
--     borttagning > tyst obsolete.
--   * Signal-in-code: samma data är nu tillgänglig via
--     knowledge_map_topics() som Overview-karta + Feed-toolbar redan
--     använder. En dörr, inte två.
--   * Migration är liten — samma CREATE OR REPLACE-mönster som ORDER 141.
--
-- ÄNDRING:
--   get_sidebar_stats() bygger nu bara { journals: [...] }. Övriga
--   fält (signatur, returtyp, LANGUAGE, SECURITY DEFINER, search_path,
--   statement_timeout, GRANT) oförändrade.
--
--   Journals-clausulen oförändrad från ORDER 141 — behåller sin
--   `irrelevant IS NOT TRUE`-filter.
--
-- FRONTEND-KOMPATIBILITET:
--   loadSidebar (index.html rad 3561) läser bara data.journals framåt
--   (topics-branchen borttagen i samma commit som denna migration).
--   Ingen annan konsument av get_sidebar_stats existerar.
-- =============================================================================


CREATE OR REPLACE FUNCTION public.get_sidebar_stats()
RETURNS json
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
SET statement_timeout = '30s'
AS $function$
  SELECT json_build_object(
    'journals', (
      SELECT json_agg(row_to_json(j)) FROM (
        SELECT journal AS "0", count(*) AS "1" FROM articles
        WHERE journal IS NOT NULL AND journal <> ''
          AND irrelevant IS NOT TRUE
        GROUP BY journal ORDER BY count(*) DESC LIMIT 30
      ) j
    )
  )
$function$;

GRANT EXECUTE ON FUNCTION public.get_sidebar_stats()
  TO anon, authenticated, service_role;


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Bara journals-nyckeln kvar
--   SELECT jsonb_object_keys(public.get_sidebar_stats()::jsonb);
--   -- expected: 1 rad "journals" (ingen "topics")
--
--   -- 2. Journals oförändrad från ORDER 141
--   SELECT jsonb_array_length((public.get_sidebar_stats() -> 'journals')::jsonb);
--   -- expected: 30 (LIMIT)
--
--   -- 3. Total count över journals är non-irrelevant subset
--   SELECT sum((j->>'1')::int) FROM json_array_elements(public.get_sidebar_stats() -> 'journals') j;
--   -- expected: nära ~30k (topp-30 av ~35k non-irrelevant fördelat över journals)
-- =============================================================================
