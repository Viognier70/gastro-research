-- =============================================================================
-- ORDER 137 — page_counts utökas med feedable + feedable_recent
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- BAKGRUND (2026-08-23):
--
--   Feed section-intro (index.html rad 2048) sade tidigare "199 articles
--   filtered for Sommelier" — men efter ORDER 136 är rollen sortnyckel,
--   inte filter. Talet 199 är dessutom p_limit (LIMIT 200 med marginal),
--   inte urvalets storlek. Det får produkten att se mindre ut än den är:
--   hero säger 466 905, kartan 34 983, sedan möter user 199.
--
--   ORDER 137 utökar labelen till "Showing 199 [most relevant] of 34 983
--   · 268 added this week · sorted for Sommelier". Totalen ska matcha
--   feed_articles_by_role:s WHERE (irrelevant IS NOT TRUE) och veckotalet
--   ska matcha Explore-kartans recent-fält (samma predikat + 7d-fönster).
--
--   Ingen av page_counts nuvarande sex fält matchar exakt:
--     * total (466 905) — hela raw-korpus, ej filtrerad
--     * new_2w (14d, ej filtrerad)
--     * new_24h (24h, ej filtrerad)
--     * relevant (44 204) — superset (inkluderar irrelevant=TRUE med
--       relevance-poäng satta före relevance-check flippa dem)
--   Två nya fält behövs i samma tabell-scan.
--
-- ÄNDRING:
--
--   page_counts() CREATE OR REPLACE — bevarar alla existerande sex fält
--   bit-för-bit, adderar:
--
--     'feedable',
--         count(*) FILTER (WHERE irrelevant IS NOT TRUE)
--
--     'feedable_recent',
--         count(*) FILTER (WHERE irrelevant IS NOT TRUE
--                            AND fetched_at > now() - interval '7 days')
--
--   Bägge computerade i SAMMA tabell-scan över articles_public — adderar
--   ~5 ms per anrop. Signatur, LANGUAGE, SECURITY DEFINER, search_path,
--   statement_timeout och GRANT-modell oförändrade.
--
-- BASELINE (mätt live 2026-08-23):
--   feedable = 34 983       (matchar exakt feed_articles_by_role's WHERE)
--   feedable_recent = 268   (samma population, senaste 7 dygn)
--
-- KOMPATIBILITET:
--   Nya fälten läggs till i jsonb-svaret; existerande konsumenter (loadCounts)
--   som bara läser total/new_2w/new_24h/analyzed/relevant/triad ignorerar
--   de nya nycklarna. Ingen breaking change.
--
-- KONSISTENS MED EXPLORE-KARTAN (knowledge_map_topics.recent):
--   Kartan använder samma predikat (fetched_at > now() - interval '7 days')
--   men lägger dessutom topic IS NOT NULL. Summan över alla topics kan
--   därför bli marginellt lägre än feedable_recent här (några rader utan
--   topic ryms i feedable_recent). Avsiktligt — feed_articles_by_role har
--   ingen topic-filter, så feedable_recent bör spegla FEED-populationen,
--   inte karta-populationen.
-- =============================================================================


CREATE OR REPLACE FUNCTION public.page_counts()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
SET statement_timeout = '30s'
AS $function$
  SELECT jsonb_build_object(
    'total',    count(*),
    'new_2w',   count(*) FILTER (WHERE fetched_at >= now() - interval '14 days'),
    'new_24h',  count(*) FILTER (WHERE fetched_at >= now() - interval '24 hours'),
    'analyzed', count(*) FILTER (WHERE has_core_claim IS TRUE),
    'relevant', count(*) FILTER (WHERE
        relevance_sci_sensory_pro        > 0
     OR relevance_sci_culinary_pro       > 0
     OR relevance_sci_gastronomy_culture > 0
     OR relevance_sci_hospitality_mgmt   > 0
     OR relevance_sci_educator_researcher > 0),
    'triad',    count(*) FILTER (WHERE
        has_episteme_sensory_pro         IS TRUE
     OR has_episteme_culinary_pro        IS TRUE
     OR has_episteme_gastronomy_culture  IS TRUE
     OR has_episteme_hospitality_mgmt    IS TRUE
     OR has_episteme_educator_researcher IS TRUE),
    -- ORDER 137 (2026-08-23): två nya fält för Feed section-intro-labelen.
    -- feedable matchar feed_articles_by_role's WHERE (irrelevant IS NOT TRUE).
    -- feedable_recent matchar Explore-kartans recent-predikat (fetched_at
    -- inom 7 dygn) + samma population.
    'feedable',
        count(*) FILTER (WHERE irrelevant IS NOT TRUE),
    'feedable_recent',
        count(*) FILTER (WHERE irrelevant IS NOT TRUE
                           AND fetched_at > now() - interval '7 days')
  )
  FROM public.articles_public
$function$;

GRANT EXECUTE ON FUNCTION public.page_counts()
  TO anon, authenticated, service_role;


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Alla åtta fält returneras
--   SELECT jsonb_object_keys(public.page_counts()) ORDER BY 1;
--   -- expected 8 rader: analyzed, feedable, feedable_recent, new_24h,
--   --                    new_2w, relevant, total, triad
--
--   -- 2. Feedable-talen matchar direkt count-fråga
--   SELECT
--     (public.page_counts() ->> 'feedable')::int         AS via_rpc_feedable,
--     (SELECT count(*) FROM public.articles_public
--       WHERE irrelevant IS NOT TRUE)                    AS direct_count;
--   -- expected: identiska (baseline 2026-08-23: 34 983)
--
--   -- 3. Feedable_recent matchar direkt count-fråga
--   SELECT
--     (public.page_counts() ->> 'feedable_recent')::int  AS via_rpc_recent,
--     (SELECT count(*) FROM public.articles_public
--       WHERE irrelevant IS NOT TRUE
--         AND fetched_at > now() - interval '7 days')    AS direct_count;
--   -- expected: identiska (baseline 2026-08-23: 268)
--
--   -- 4. Existerande fält oförändrade
--   SELECT public.page_counts() -> 'total'    AS total,
--          public.page_counts() -> 'triad'    AS triad,
--          public.page_counts() -> 'relevant' AS relevant;
--   -- expected: samma som före apply (466 905 / 39 182 / 44 204 approx)
-- =============================================================================
