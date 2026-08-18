-- =============================================================================
-- map_coverage() — båda coverage-talen i en tabellskanning.
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. En push skulle försöka köra om dem, inkl.
-- omklassificeringen av 18 131 artiklar. Se ORDER 091 §8.)
--
-- BAKGRUND (ORDER 094 / 093-diagnos 2026-08-18):
--
--   updateMapCoverageCopy (index.html rad ~6159) fyrar två parallella
--   Prefer:count=exact-fetches mot articles_public. Predikatet har fem-vägs
--   has_episteme_<role> OR + irrelevant=false + primary_institution not null
--   över 466 905 rader. Från browsern under konkurrent belastning svarar
--   PostgREST 500 på minst en av dem — coverage-copyn faller till
--   "unavailable". Direkt curl fungerar (ingen konkurrens).
--
--   ORDER 093 §2.3-loggen bevisade orsaken:
--     [coverage-copy] countOf null {"label":"total","status":500,...}
--
-- LÖSNING:
--
--   En SECURITY DEFINER RPC som räknar båda talen i EN tabellskanning
--   med count(*) FILTER (WHERE …). Undviker PostgREST count=exact-overhead
--   och parallell-belastning.
--
-- PREDIKAT (identiskt med updateMapCoverageCopy):
--
--   irrelevant = false
--     AND primary_institution IS NOT NULL
--     AND (has_episteme_<role> för minst en av fem roller)
--
--   TRIAD-gaten läses här som phronesis_<role> IS NOT NULL — canary-
--   fältet från triad_coverage() (ORDER 091 §6). TRIAD-pipelinen skriver
--   ε/τ/φ atomärt per roll: has_episteme_X ⇔ phronesis_X is not null.
--   (RPC:n läser från articles, inte articles_public — där finns bara
--   phronesis-kolumnerna, inte has_episteme_-booleans.)
--
--   irrelevant-gaten: articles_public exponerar bara `irrelevant is not
--   true` (dvs false ELLER null). Använd samma mönster här: matcha
--   inte bara false utan även null.
--
-- RETURN: jsonb {"with_coords": bigint, "total": bigint}
--   Match för triad_coverage()-parsemönster i frontenden — await r.json()
--   ger objekt direkt, ingen array-unwrap (som TABLE-return skulle kräva).
--
-- FÖRVÄNTAT VID VERIFIERING:
--   select public.map_coverage();
--     → {"with_coords": 20283, "total": 28553}
--   ± några dagar av nya artiklar. Skiljer talen storleksordning: fel
--   predikat, granska irrelevant-gaten först.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.map_coverage()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
SET statement_timeout = '30s'
AS $function$
  SELECT jsonb_build_object(
    'with_coords', count(*) FILTER (
      WHERE institution_coords IS NOT NULL
        AND jsonb_array_length(institution_coords) > 0
    ),
    'total',       count(*)
  )
  FROM public.articles
  WHERE irrelevant IS NOT TRUE
    AND primary_institution IS NOT NULL
    AND (phronesis_sensory_pro         IS NOT NULL
      OR phronesis_culinary_pro        IS NOT NULL
      OR phronesis_gastronomy_culture  IS NOT NULL
      OR phronesis_hospitality_mgmt    IS NOT NULL
      OR phronesis_educator_researcher IS NOT NULL)
$function$;

GRANT EXECUTE ON FUNCTION public.map_coverage()
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.map_coverage() IS
  'Kart-coveragens two-in-one: {with_coords, total} över TRIAD-analyserade '
  'artiklar med institution. Ersätter två parallella articles_public '
  'Prefer:count=exact-fetches som fick 500 under samtidig belastning. '
  'Predikat identiskt med updateMapCoverageCopy (ORDER 091 §6 + 094).';
