-- =============================================================================
-- triad_coverage() — kanonisk siffra för "artiklar med TRIAD-analys".
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men inte registrerade i
-- schema_migrations. En push skulle försöka köra om dem, inkl.
-- omklassificeringen av 18 131 artiklar. Se ORDER 091 §8.)
--
-- BAKGRUND (ORDER 091 §6, utredning 2026-08-18):
--
--   Sajten visade minst fyra olika tal för "TRIAD-täckning" — 5 200 / 9 714 /
--   28 553 / 34 628 — som mätte olika saker:
--     - articles.triad_completed_at is not null → 34 628 (steget passerat,
--       inkluderar skippade — inte analysinnehåll)
--     - article_claims / article_roles → 1 088 (parallell struktur, byggd
--       men inte fylld, DISJUNKT från de 39 141)
--     - kartans "TRIAD-analysed" → articles_public med coords (fel label)
--     - Overview watchbar → hårdkodad fallback 9 714
--
--   TRIAD lagras i femton kolumner på articles: episteme_*, techne_*,
--   phronesis_* för fem yrkesroller (sensory_pro, culinary_pro,
--   gastronomy_culture, hospitality_mgmt, educator_researcher).
--
-- AUKTORITATIV DEFINITION:
--
--   En artikel räknas som TRIAD-analyserad om minst en av de fem rollerna
--   har phronesis_<role> ifylld. Phronesis är canary-fältet: TRIAD-
--   pipelinen skriver episteme/techne/phronesis atomärt per roll
--   (samma prompt-anrop), så phronesis is not null ⇒ hela rollen ifylld.
--
--   Per 2026-08-18: 39 141 artiklar. Spridningen över alla fem roller är
--   sju artiklar — täckningen är i praktiken komplett över alla roller.
--
--   INGEN irrelevant-gate här. RPC:n returnerar det analytiska talet;
--   exponerings-gating är ett separat lager (articles_public).
--
-- MÖNSTER: SECURITY DEFINER + SET search_path + SET statement_timeout,
-- följer 20260804120000_map_institution_coords_rpc.sql.
--
-- KONSUMENTER (alla vyer som visar ett TRIAD-tal SKA läsa från denna RPC):
--   - landing-hero sifferband #landingTriadCount (§5)
--   - Feed hero-stats #triadCount
--   - data-panel #dp-triad-count
--   - upgrade-modal #upgrade-triad-count
--   - onboarding #obSubText
--   - renderOversiktWatchBar (window._triadCount)
-- Ingen vy räknar själv. Ingen hårdkodad TRIAD-siffra i markup.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.triad_coverage()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
SET statement_timeout = '30s'
AS $function$
  SELECT COUNT(*)::bigint
  FROM public.articles
  WHERE phronesis_sensory_pro         IS NOT NULL
     OR phronesis_culinary_pro        IS NOT NULL
     OR phronesis_gastronomy_culture  IS NOT NULL
     OR phronesis_hospitality_mgmt    IS NOT NULL
     OR phronesis_educator_researcher IS NOT NULL
$function$;

GRANT EXECUTE ON FUNCTION public.triad_coverage()
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.triad_coverage() IS
  'Antal articles med TRIAD-analys (phronesis ifylld för minst en av fem roller). '
  'Kanonisk källa per ORDER 091 §6. Ersätter tidigare parallella tal från '
  'screening_funnel.triad_analyserade, articles_public-count, hårdkodade '
  'fallbacks 5200/9714 och article_claims/article_roles.';
