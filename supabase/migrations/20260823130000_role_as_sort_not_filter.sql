-- =============================================================================
-- ORDER 136 — Roll blir sortering, inte filter
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- BAKGRUND (2026-08-23):
--
--   Beslut: gastronomiska yrkesroller flyter in i varandra och kommer göra
--   det mer (kockar arbetar i matsalen, sommelierer experimenterar med
--   mat). Produkten ska främja det, inte cementera skrån. Rollen blir en
--   SORTERINGSNYCKEL — vilka artiklar som är mest relevanta för mig — inte
--   ett FILTER som utesluter artiklar från andra roller.
--
--   Fyra RPC:er hade CASE-per-role-filter i WHERE-clausulen som utestängde
--   artiklar utan role-specifik TRIAD/sci. I praktiken var utfallet små
--   (~1.5 % population) eftersom TRIAD skrivs atomärt över alla 5 roller,
--   men principiellt fel: rollen borde aldrig hindra en användare från
--   att SE en artikel — bara ordna dem.
--
-- ÄNDRINGAR (fyra RPC:er, alla CREATE OR REPLACE — signaturer + returtyper
-- + column-listor + LANGUAGE/SECURITY DEFINER/SET/GRANT oförändrade):
--
--   1. feed_articles_by_role
--      DROP: WHERE (CASE p_role... has_episteme_<role> END IS TRUE
--                   OR CASE p_role... has_sci_<role> END IS TRUE)
--      ORDER BY relevance_sci_<role> DESC NULLS LAST, fetched_at DESC, id ASC — oförändrad
--
--   2. spotlight_articles
--      DROP: WHERE CASE p_role... has_episteme_<role> END IS TRUE
--      KEEP: WHERE CASE p_role... relevance_sci_<role> END >= 5
--            (>= 5 är KVALITETSFILTER oberoende av roll — behålls)
--      ORDER BY year DESC, fetched_at DESC, id ASC — oförändrad
--
--   3. explore_articles
--      DROP: hela WHERE (p_role='all' AND ANY has_ep OR p_role<>'all' AND CASE... has_ep END)
--      KEEP: topic = p_topic filter (Explore filtrerar på ämne, inte roll)
--      ORDER BY relevance_sci_<role> DESC NULLS LAST, ... — oförändrad
--
--   4. oversikt_lead_article
--      DROP: WHERE (CASE p_role... has_episteme_<role> OR CASE... has_sci_<role>)
--      KEEP: fetched_at >= p_since + irrelevant IS NOT TRUE
--      ORDER BY relevance_sci_<role> DESC NULLS LAST, ... — oförändrad
--
-- BEHÅLLS EXPLICIT (per beslut 2026-08-23):
--   * weekly-newsletter .not(episteme_${col}, 'is', null) — per-roll-TRIAD
--     är brevets värde, inte ett rollfilter (edge-fn, ej migration)
--   * hasTriadPresence per-kort UI-check — separat designfråga (index.html)
--
-- INGA POPULATIONSFÖRLUSTER: mätt 2026-08-23, sommelier-Feed går från
-- 34,465 rader till 34,983 rader (+518, ~1.5 %). Diffen är så liten
-- eftersom TRIAD skrivs atomärt över alla 5 roller — filtren utestängde
-- främst artiklar som är non-irrelevant men saknar TRIAD helt (i pipelinekö).
--
-- SÄKERHET: Alla fyra fn:er behåller SECURITY DEFINER + search_path=public,
-- pg_temp + statement_timeout=30s. Ingen strängkonkatenering — CASE p_role
-- över whitelist. Grant-modellen orörd (anon/authenticated/service_role).
-- =============================================================================


-- =============================================================================
-- §1 — feed_articles_by_role: filter bort, sort behåll
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
    -- ORDER 136: has_episteme/has_sci-filtret borttaget. Rollen är
    -- nu ren sortnyckel (ORDER BY nedan) — hela non-irrelevant-korpusen
    -- är nåbar oavsett roll.
  ORDER BY
    CASE p_role
      WHEN 'sensory_pro'          THEN relevance_sci_sensory_pro
      WHEN 'culinary_pro'         THEN relevance_sci_culinary_pro
      WHEN 'gastronomy_culture'   THEN relevance_sci_gastronomy_culture
      WHEN 'hospitality_mgmt'     THEN relevance_sci_hospitality_mgmt
      WHEN 'educator_researcher'  THEN relevance_sci_educator_researcher
    END DESC NULLS LAST,
    fetched_at DESC,
    id ASC
  LIMIT p_limit
$function$;

GRANT EXECUTE ON FUNCTION public.feed_articles_by_role(text, integer)
  TO anon, authenticated, service_role;


-- =============================================================================
-- §2 — spotlight_articles: has_ep-filter bort, >= 5-tröskel behåll
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
    -- ORDER 136: has_episteme_<role>-filtret borttaget (rollen ska inte
    -- utestänga artiklar). >= 5-tröskeln nedan BEHÅLLS som kvalitetsfilter
    -- — den räknar "modellen bedömer artikeln relevant för denna roll",
    -- vilket är rätt kriterium för en SPOTLIGHT (bäst-för-rollen), inte
    -- ett role-exkluderande filter.
    AND CASE p_role
          WHEN 'sensory_pro'          THEN relevance_sci_sensory_pro
          WHEN 'culinary_pro'         THEN relevance_sci_culinary_pro
          WHEN 'gastronomy_culture'   THEN relevance_sci_gastronomy_culture
          WHEN 'hospitality_mgmt'     THEN relevance_sci_hospitality_mgmt
          WHEN 'educator_researcher'  THEN relevance_sci_educator_researcher
        END >= 5
  ORDER BY year DESC, fetched_at DESC, id ASC
  LIMIT p_limit
$function$;

GRANT EXECUTE ON FUNCTION public.spotlight_articles(text, integer)
  TO anon, authenticated, service_role;


-- =============================================================================
-- §3 — explore_articles: has_ep-filter bort, topic-filter behåll
-- =============================================================================
CREATE OR REPLACE FUNCTION public.explore_articles(
  p_role  text,
  p_topic text,
  p_limit integer DEFAULT 100
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
  has_imrad                         boolean,
  primary_institution               text,
  institution_rank                  integer,
  citation_count                    integer
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
    has_core_claim, has_imrad,
    primary_institution, institution_rank, citation_count
  FROM public.articles_public
  WHERE p_role = ANY(ARRAY[
          'all','sensory_pro','culinary_pro','gastronomy_culture',
          'hospitality_mgmt','educator_researcher'])
    AND p_topic IS NOT NULL
    AND topic = p_topic
    AND irrelevant IS NOT TRUE
    -- ORDER 136: has_episteme-filter (både 'all'-grenen och per-role-grenen)
    -- borttaget. Explore filtrerar på ÄMNE (topic = p_topic ovan) — rollen
    -- ska bara ordna vilka artiklar inom ämnet som är mest relevanta.
  ORDER BY
    CASE p_role
      WHEN 'sensory_pro'          THEN relevance_sci_sensory_pro
      WHEN 'culinary_pro'         THEN relevance_sci_culinary_pro
      WHEN 'gastronomy_culture'   THEN relevance_sci_gastronomy_culture
      WHEN 'hospitality_mgmt'     THEN relevance_sci_hospitality_mgmt
      WHEN 'educator_researcher'  THEN relevance_sci_educator_researcher
    END DESC NULLS LAST,
    CASE WHEN p_role = 'all' THEN year END DESC NULLS LAST,
    fetched_at DESC,
    id ASC
  LIMIT p_limit
$function$;

GRANT EXECUTE ON FUNCTION public.explore_articles(text, text, integer)
  TO anon, authenticated, service_role;


-- =============================================================================
-- §4 — oversikt_lead_article: has_ep/has_sci-filter bort
-- =============================================================================
CREATE OR REPLACE FUNCTION public.oversikt_lead_article(
  p_role  text,
  p_since timestamptz
)
RETURNS TABLE(
  id             uuid,
  title          text,
  headline_en    text,
  journal        text,
  year           text,
  url            text,
  fetched_at     timestamptz,
  insight        text,
  limitation     text,
  relevance_sci  integer,
  has_core_claim boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
SET statement_timeout = '30s'
AS $function$
  SELECT
    id, title, headline_en, journal, year, url, fetched_at, insight, limitation,
    CASE p_role
      WHEN 'sensory_pro'          THEN relevance_sci_sensory_pro
      WHEN 'culinary_pro'         THEN relevance_sci_culinary_pro
      WHEN 'gastronomy_culture'   THEN relevance_sci_gastronomy_culture
      WHEN 'hospitality_mgmt'     THEN relevance_sci_hospitality_mgmt
      WHEN 'educator_researcher'  THEN relevance_sci_educator_researcher
    END AS relevance_sci,
    has_core_claim
  FROM public.articles_public
  WHERE p_role = ANY(ARRAY[
          'sensory_pro','culinary_pro','gastronomy_culture',
          'hospitality_mgmt','educator_researcher'])
    AND p_since IS NOT NULL
    AND irrelevant IS NOT TRUE
    AND fetched_at >= p_since
    -- ORDER 136: has_episteme/has_sci-filter borttaget. Oversikt-lead
    -- ska visa DEN MEST RELEVANTA nya artikeln för rollen sedan senaste
    -- besök — inte utesluta artiklar som saknar per-roll-TRIAD.
  ORDER BY
    CASE p_role
      WHEN 'sensory_pro'          THEN relevance_sci_sensory_pro
      WHEN 'culinary_pro'         THEN relevance_sci_culinary_pro
      WHEN 'gastronomy_culture'   THEN relevance_sci_gastronomy_culture
      WHEN 'hospitality_mgmt'     THEN relevance_sci_hospitality_mgmt
      WHEN 'educator_researcher'  THEN relevance_sci_educator_researcher
    END DESC NULLS LAST,
    year DESC NULLS LAST,
    fetched_at DESC,
    id ASC
  LIMIT 1
$function$;

GRANT EXECUTE ON FUNCTION public.oversikt_lead_article(text, timestamptz)
  TO anon, authenticated, service_role;


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Populationsstorlek per RPC (sommelier)
--   SELECT count(*) FROM public.feed_articles_by_role('sensory_pro', 100000);
--   -- expected: ~34,983 (mätt 2026-08-23 non-irrelevant, +518 mot tidigare 34,465)
--
--   SELECT count(*) FROM public.spotlight_articles('sensory_pro', 100000);
--   -- expected: mindre än ovan (>=5-tröskeln filtrerar) — mät baseline
--
--   -- 2. Sortering bevarad: topp-1 för olika roller ska SKILJA sig
--   SELECT (public.feed_articles_by_role('sensory_pro', 1)).*;
--   SELECT (public.feed_articles_by_role('culinary_pro', 1)).*;
--   -- expected: olika topp-artikel (sortering per relevance_sci_<role>)
--
--   -- 3. Explore hämtar samma topic för olika roller men olika ordning
--   SELECT id, title FROM public.explore_articles('sensory_pro', 'gastronomy', 3);
--   SELECT id, title FROM public.explore_articles('culinary_pro', 'gastronomy', 3);
--   -- expected: samma population inom topic, olika topp-3
--
--   -- 4. oversikt_lead_article returnerar en artikel för alla roller
--   SELECT title FROM public.oversikt_lead_article('sensory_pro',
--                                                   now() - interval '30 days');
--   SELECT title FROM public.oversikt_lead_article('educator_researcher',
--                                                   now() - interval '30 days');
--   -- expected: bägge returnerar 1 rad (educator gav tidigare 0 om ingen
--   -- educator-TRIAD-artikel fanns under fönstret)
-- =============================================================================
