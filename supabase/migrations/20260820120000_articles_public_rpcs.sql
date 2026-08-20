-- =============================================================================
-- spotlight_articles / ticker_articles / feed_articles_by_role
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- BAKGRUND (ORDER 107, 2026-08-20):
--
--   loadSpotlight, loadMiniTicker och den role-specifika grenen av
--   loadArticles (culinary_pro m.fl.) fetchar direkt mot articles_public
--   utan RPC-wrap. Anon default statement_timeout ~3s. Curl-mätning
--   2026-08-20:
--     - Seriellt (varm cache):    0.4–1.7s per query — OK
--     - Parallellt (page-load):   3.13–3.21s per query — vid gränsen
--   Under samtidig load (enrichWithPremiumIfPro + trending/mostcited/
--   sidebar-RPC:er från samma page-open) tippar de över till 57014 →
--   500 → Spotlight visar "No findings", Ticker fastnar på placeholder.
--
--   Samma lösning som ORDER 105 (feed_articles): SECURITY DEFINER-RPC
--   med statement_timeout=30s. Predikat, sortering, kolumnval är
--   IDENTISKA med dagens direktfetch — ingen semantik-förändring.
--
-- SÄKERHET: p_role via CASE, aldrig strängkonkatenering.
--
--   PostgREST-anrop skickar p_role som textparameter. Om vi bygger en
--   kolumnnamn-sträng ('has_episteme_' || p_role) och kör EXECUTE
--   USING öppnar det för SQL-injektion (t.ex. p_role='sensory_pro;
--   DROP TABLE ...'). CASE-uttryck mappar däremot p_role mot en
--   sluten uppsättning EXPLICITA kolumn-identifierare — planern
--   löser dem statiskt, ogiltiga p_role-värden ger NULL → 0 rader.
--
--   Extra bältet-och-hängslen: WHERE p_role = ANY(ARRAY[...5 roller])
--   som första predikat kort-cirkuterar hela querien för ogiltig
--   input (RAISE-alternativ skulle kräva LANGUAGE plpgsql och göra
--   RPC:n VOLATILE — CASE + WHERE-guard håller LANGUAGE sql STABLE).
-- =============================================================================

-- =============================================================================
-- §1 — spotlight_articles(p_role, p_limit)
--   Ersätter loadSpotlight (index.html ~6189).
--   Predikat: has_episteme_<role>=true AND relevance_sci_<role>>=5
--   Sortering: year desc, fetched_at desc
-- =============================================================================
CREATE OR REPLACE FUNCTION public.spotlight_articles(
  p_role  text,
  p_limit integer DEFAULT 7
)
RETURNS TABLE(
  id             uuid,
  title          text,
  headline_en    text,
  journal        text,
  year           text,
  url            text,
  fetched_at     timestamptz,
  relevance_sci  integer,
  citation_count integer,
  has_core_claim boolean,
  has_episteme   boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
SET statement_timeout = '30s'
AS $function$
  SELECT
    id, title, headline_en, journal, year, url, fetched_at,
    CASE p_role
      WHEN 'sensory_pro'          THEN relevance_sci_sensory_pro
      WHEN 'culinary_pro'         THEN relevance_sci_culinary_pro
      WHEN 'gastronomy_culture'   THEN relevance_sci_gastronomy_culture
      WHEN 'hospitality_mgmt'     THEN relevance_sci_hospitality_mgmt
      WHEN 'educator_researcher'  THEN relevance_sci_educator_researcher
    END AS relevance_sci,
    citation_count,
    has_core_claim,
    CASE p_role
      WHEN 'sensory_pro'          THEN has_episteme_sensory_pro
      WHEN 'culinary_pro'         THEN has_episteme_culinary_pro
      WHEN 'gastronomy_culture'   THEN has_episteme_gastronomy_culture
      WHEN 'hospitality_mgmt'     THEN has_episteme_hospitality_mgmt
      WHEN 'educator_researcher'  THEN has_episteme_educator_researcher
    END AS has_episteme
  FROM public.articles_public
  WHERE p_role = ANY(ARRAY[
          'sensory_pro','culinary_pro','gastronomy_culture',
          'hospitality_mgmt','educator_researcher'])
    AND irrelevant IS NOT TRUE
    AND CASE p_role
          WHEN 'sensory_pro'          THEN has_episteme_sensory_pro
          WHEN 'culinary_pro'         THEN has_episteme_culinary_pro
          WHEN 'gastronomy_culture'   THEN has_episteme_gastronomy_culture
          WHEN 'hospitality_mgmt'     THEN has_episteme_hospitality_mgmt
          WHEN 'educator_researcher'  THEN has_episteme_educator_researcher
        END IS TRUE
    AND CASE p_role
          WHEN 'sensory_pro'          THEN relevance_sci_sensory_pro
          WHEN 'culinary_pro'         THEN relevance_sci_culinary_pro
          WHEN 'gastronomy_culture'   THEN relevance_sci_gastronomy_culture
          WHEN 'hospitality_mgmt'     THEN relevance_sci_hospitality_mgmt
          WHEN 'educator_researcher'  THEN relevance_sci_educator_researcher
        END >= 5
  ORDER BY year DESC, fetched_at DESC
  LIMIT p_limit
$function$;

GRANT EXECUTE ON FUNCTION public.spotlight_articles(text, integer)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.spotlight_articles(text, integer) IS
  'Research Spotlight-fetch. Ersätter direktfetch mot articles_public i '
  'loadSpotlight (index.html). CASE över p_role — ingen strängkonkatenering. '
  'statement_timeout=30s (ORDER 107, 2026-08-20).';


-- =============================================================================
-- §2 — ticker_articles(p_limit)
--   Ersätter loadMiniTicker (index.html ~5964).
--   Predikat: or(has_episteme_<role>) över alla 5 roller (rollagnostisk).
--   Sortering: year desc nulls last
-- =============================================================================
CREATE OR REPLACE FUNCTION public.ticker_articles(
  p_limit integer DEFAULT 10
)
RETURNS TABLE(
  title   text,
  journal text,
  year    text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
SET statement_timeout = '30s'
AS $function$
  SELECT title, journal, year
  FROM public.articles_public
  WHERE irrelevant IS NOT TRUE
    AND (has_episteme_sensory_pro         IS TRUE
      OR has_episteme_culinary_pro        IS TRUE
      OR has_episteme_gastronomy_culture  IS TRUE
      OR has_episteme_hospitality_mgmt    IS TRUE
      OR has_episteme_educator_researcher IS TRUE)
  ORDER BY year DESC NULLS LAST
  LIMIT p_limit
$function$;

GRANT EXECUTE ON FUNCTION public.ticker_articles(integer)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.ticker_articles(integer) IS
  'Incoming Research-ticker. Ersätter direktfetch i loadMiniTicker '
  '(index.html). Ingen p_role — visar över alla 5 roller. '
  'statement_timeout=30s (ORDER 107, 2026-08-20).';


-- =============================================================================
-- §3 — feed_articles_by_role(p_role, p_limit)
--   Ersätter loadArticles role='specifikt'-grenen (index.html ~3300).
--   Predikat: or(has_episteme_<role>, has_sci_<role>)
--   Sortering: relevance_sci_<role> desc nulls last, fetched_at desc
--   28 kolumner — MATCHAR feed_articles(p_limit) för role='all'-grenen.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.feed_articles_by_role(
  p_role  text,
  p_limit integer DEFAULT 200
)
RETURNS TABLE(
  id                                uuid,
  headline_en                       text,
  title                             text,
  topic                             text,
  source_label                      text,
  insight                           text,
  limitation                        text,
  study_type                        text,
  year                              text,
  authors                           text,
  journal                           text,
  url                               text,
  knowledge_type                    text,
  country                           text,
  countries                         text[],
  keywords                          text[],
  relevance_sci_sensory_pro         integer,
  relevance_sci_culinary_pro        integer,
  relevance_sci_gastronomy_culture  integer,
  relevance_sci_hospitality_mgmt    integer,
  relevance_sci_educator_researcher integer,
  has_episteme_sensory_pro          boolean,
  has_episteme_culinary_pro         boolean,
  has_episteme_gastronomy_culture   boolean,
  has_episteme_hospitality_mgmt     boolean,
  has_episteme_educator_researcher  boolean,
  has_core_claim                    boolean,
  has_imrad                         boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
SET statement_timeout = '30s'
AS $function$
  SELECT
    id, headline_en, title, topic, source_label, insight, limitation, study_type,
    year, authors, journal, url, knowledge_type, country, countries, keywords,
    relevance_sci_sensory_pro, relevance_sci_culinary_pro,
    relevance_sci_gastronomy_culture, relevance_sci_hospitality_mgmt,
    relevance_sci_educator_researcher,
    has_episteme_sensory_pro, has_episteme_culinary_pro,
    has_episteme_gastronomy_culture, has_episteme_hospitality_mgmt,
    has_episteme_educator_researcher,
    has_core_claim, has_imrad
  FROM public.articles_public
  WHERE p_role = ANY(ARRAY[
          'sensory_pro','culinary_pro','gastronomy_culture',
          'hospitality_mgmt','educator_researcher'])
    AND irrelevant IS NOT TRUE
    AND (
      CASE p_role
        WHEN 'sensory_pro'          THEN has_episteme_sensory_pro
        WHEN 'culinary_pro'         THEN has_episteme_culinary_pro
        WHEN 'gastronomy_culture'   THEN has_episteme_gastronomy_culture
        WHEN 'hospitality_mgmt'     THEN has_episteme_hospitality_mgmt
        WHEN 'educator_researcher'  THEN has_episteme_educator_researcher
      END IS TRUE
      OR
      CASE p_role
        WHEN 'sensory_pro'          THEN has_sci_sensory_pro
        WHEN 'culinary_pro'         THEN has_sci_culinary_pro
        WHEN 'gastronomy_culture'   THEN has_sci_gastronomy_culture
        WHEN 'hospitality_mgmt'     THEN has_sci_hospitality_mgmt
        WHEN 'educator_researcher'  THEN has_sci_educator_researcher
      END IS TRUE
    )
  ORDER BY
    CASE p_role
      WHEN 'sensory_pro'          THEN relevance_sci_sensory_pro
      WHEN 'culinary_pro'         THEN relevance_sci_culinary_pro
      WHEN 'gastronomy_culture'   THEN relevance_sci_gastronomy_culture
      WHEN 'hospitality_mgmt'     THEN relevance_sci_hospitality_mgmt
      WHEN 'educator_researcher'  THEN relevance_sci_educator_researcher
    END DESC NULLS LAST,
    fetched_at DESC
  LIMIT p_limit
$function$;

GRANT EXECUTE ON FUNCTION public.feed_articles_by_role(text, integer)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.feed_articles_by_role(text, integer) IS
  'Feed-läsning för role-specifik grenen. Ersätter direktfetch mot '
  'articles_public i loadArticles (index.html) när role !== all. '
  'CASE över p_role — ingen strängkonkatenering. Samma 28-kolumner '
  'som feed_articles(). statement_timeout=30s (ORDER 107, 2026-08-20).';


-- =============================================================================
-- SCHEMA-CACHE RELOAD
-- =============================================================================
-- Utan denna ser PostgREST inte de nya funktionerna förrän intern cache-
-- polling tickar (kan ta minuter). Frontend får 404 emellan. NOTIFY
-- pgrst 'reload schema' triggar omedelbar re-introspection.
-- =============================================================================
NOTIFY pgrst, 'reload schema';


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--   select count(*) from public.spotlight_articles('culinary_pro', 7);
--   -- expected: 0–7
--   select count(*) from public.ticker_articles(10);
--   -- expected: 10 (limit-taket) på normal-läge
--   select count(*) from public.feed_articles_by_role('culinary_pro', 200);
--   -- expected: 0–200
--
--   -- Ogiltig roll ska ge 0 rader (WHERE-guarden), inte error:
--   select count(*) from public.spotlight_articles('robert''; DROP TABLE x;--', 7);
--   -- expected: 0
--   select count(*) from public.feed_articles_by_role('all', 200);
--   -- expected: 0 (role='all' hanteras av feed_articles(), inte denna)
--
--   -- PostgREST-syn på RPC:erna (curl utifrån):
--   -- curl -H "apikey:$ANON" -H "Authorization:Bearer $ANON" \
--   --   "$SB/rest/v1/rpc/ticker_articles" -X POST -d '{"p_limit":3}'
--   -- expected: [{...},{...},{...}]
-- =============================================================================
