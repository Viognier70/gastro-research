-- =============================================================================
-- ORDER 141 — get_sidebar_stats filtrerar nu irrelevant + uncategorized
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- BAKGRUND (2026-08-23):
--
--   Feed-sidopanelens "Top topics" visade groteskt uppblåsta siffror —
--   gastronomy 357,129 mot Overview-kartans 794 (357k gastronomy?), och
--   summan över alla 20 topics ~467k = HELA raw-korpusen.
--
--   Rot: get_sidebar_stats() SQL:en läste `count(*) FROM articles WHERE
--   topic IS NOT NULL` utan `AND irrelevant IS NOT TRUE`-filter. Den
--   räknade alla artiklar OpenAlex/PubMed skickat med en keyword-match
--   för topic X — INKLUSIVE de ~432k som Haiku:s relevance-check senare
--   flippat till irrelevant=true (typisk falsk träff: "food" i medicinsk
--   toxikologi, "wine" i psykiatri, etc).
--
--   Effekt för användaren: klick på "gastronomy 357k" → Feed visar ≤200
--   artiklar av vilka nästan alla är non-irrelevant → diskrepans 350k+.
--   Overview-kartan sa 794 för samma topic. Två räknare för samma sak,
--   en 450x större än den andra, ingen förklaring.
--
-- FIX — matcha feed_articles_by_role's WHERE-clausul:
--   * Topics: lägg till `AND irrelevant IS NOT TRUE`
--            + `AND topic <> 'uncategorized'` (matchar Feed-toolbarens
--              populateTopicSelect från ORDER 140 som exkluderar
--              fallback-bucketen)
--   * Journals: lägg till `AND irrelevant IS NOT TRUE`
--
-- BASELINE (mätt live 2026-08-23):
--   Före:  topics.gastronomy = 357,129    journals.total ≈ 467k
--   Efter: topics.gastronomy = 794         journals.total ≈ 35k
--
-- KOMPATIBILITET: JSON-struktur oförändrad — bara siffror ändras.
-- Frontend (loadSidebar rad 3561) läser samma nycklar och behöver ingen
-- ändring. Signatur/LANGUAGE/SECURITY DEFINER/search_path/statement_timeout/
-- GRANT-modell oförändrade.
--
-- KVARSTÅENDE OPEN QUESTION (rapporterad i egen order):
--   Sidopanelens "Top topics" är efter ORDER 140 (Feed-toolbaren har
--   levande topic-counts) funktionellt REDUNDANT — bägge filtrerar
--   Feed på samma topic-lista med samma counts. Journals + Most cited +
--   Research pulse är unika data-cuts som fyller sitt syfte. Om Anders
--   accepterar "Top topics"-borttagning blir denna migration ändå
--   användbar för journals-räknaren som förblir aktiv.
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
    'topics', (
      SELECT json_agg(row_to_json(t)) FROM (
        SELECT topic AS "0", count(*) AS "1" FROM articles
        WHERE topic IS NOT NULL
          -- ORDER 141: matcha Overview-karta och Feed-toolbar (ORDER 140)
          AND irrelevant IS NOT TRUE
          AND topic <> 'uncategorized'
        GROUP BY topic ORDER BY count(*) DESC LIMIT 20
      ) t
    ),
    'journals', (
      SELECT json_agg(row_to_json(j)) FROM (
        SELECT journal AS "0", count(*) AS "1" FROM articles
        WHERE journal IS NOT NULL AND journal <> ''
          -- ORDER 141: matcha Feed-filtret så klick på journal ger
          -- meningsfull filtering (feed_articles_by_role har samma predikat)
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
--   -- 1. Topics matchar Overview-karta för samma topic
--   SELECT (public.get_sidebar_stats() -> 'topics') -> 0 AS top_topic;
--   -- expected: {"0":"food_science","1":8277} (matchar knowledge_map_topics
--   -- efter att uncategorized exkluderats; food_science är största non-uncat)
--
--   -- 2. Uncategorized inte längre med
--   SELECT jsonb_array_length((public.get_sidebar_stats() -> 'topics')::jsonb) AS n_topics;
--   -- expected: <= 20 (LIMIT); uncategorized inte i listan
--
--   SELECT (public.get_sidebar_stats() -> 'topics') @> '[{"0":"uncategorized"}]'::json;
--   -- expected: false
--
--   -- 3. Summan över topics är nu ~35k (non-irrelevant), inte ~467k
--   SELECT sum((t->>'1')::int) AS total_topic_count
--     FROM json_array_elements(public.get_sidebar_stats() -> 'topics') t;
--   -- expected: ~34,000 (feedable från page_counts minus uncategorized-bucket)
--
--   -- 4. Journals också filtrerad
--   SELECT sum((j->>'1')::int) AS total_journal_count
--     FROM json_array_elements(public.get_sidebar_stats() -> 'journals') j;
--   -- expected: <= feedable, nära ~30k (top-30 journals)
-- =============================================================================
