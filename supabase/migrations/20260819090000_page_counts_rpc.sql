-- =============================================================================
-- page_counts() — sex räknare i EN tabellskanning för loadCounts.
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. En push skulle försöka köra om dem, inkl.
-- omklassificeringen av 18 131 artiklar. Se ORDER 091 §8.)
--
-- BAKGRUND (ORDER 097b, 2026-08-19):
--
--   ORDER 096 §1 verifiering visade 11 återstående 500-fel efter att
--   get_trending_keywords fixats. 9 av 11 var count=exact-fetches mot
--   articles_public — samma familj som blockerade map_coverage innan
--   ORDER 094. loadCounts fyrade 6 parallella head-count-queryer under
--   första sidladdningen:
--
--     r1: articles_public                                    → total
--     r2: articles_public + fetched_at gte now-14d           → nya på 2v
--     r4: articles_public + has_core_claim=is.true           → analyzed
--     r5: articles_public + or(relevance_sci_*.gt.0)         → relevant
--     r6: articles_public + or(has_episteme_*.is.true)       → triad_public
--     r8: articles_public + fetched_at gte now-24h           → nya på 24h
--
--   Varje query gör en full scan över 466 905 rader med Prefer:count=exact.
--   Sex parallella slår i default statement_timeout (~3 s) i första
--   sekunden av sidladdning; några får HTTP 500.
--
-- LÖSNING (rot, inte symptom):
--
--   En SECURITY DEFINER RPC som räknar alla sex talen i EN tabellskanning
--   med count(*) FILTER (WHERE …). Sex parallella count=exact → en
--   POST /rest/v1/rpc/page_counts. Ersätter dessutom framtida behov av
--   statement_timeout-höjning på RPC:er som slöts av samma pool.
--
--   Läser articles_public (samma vy som frontend läste), så gate:ing
--   (irrelevant is not true) är IDENTISK — talen matchar r1/r2/r4/r5/r6/r8
--   utan skiften. Detta är också vad Anders krävde i ORDER 097b.
--
-- BASELINE (verifierat via curl 2026-08-19):
--   total = 466 905, new_2w = 0, new_24h = 0,
--   analyzed = 46 302, relevant = 44 204, triad = 39 182
--   (new_2w/new_24h är 0 för pipeline sover — inte fel i räknaren)
--
-- RETURN: jsonb med sex bigint-fält. Följer map_coverage()-parsemönster.
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
     OR has_episteme_educator_researcher IS TRUE)
  )
  FROM public.articles_public
$function$;

GRANT EXECUTE ON FUNCTION public.page_counts()
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.page_counts() IS
  'Sex räknare för loadCounts i en tabellskanning över articles_public. '
  'Ersätter sex parallella Prefer:count=exact-fetches som skapade '
  'HTTP 500-storm under sidladdning (ORDER 097b, 2026-08-19). '
  'Predikat identiska med de gamla queryerna — talen matchar bit-för-bit.';
