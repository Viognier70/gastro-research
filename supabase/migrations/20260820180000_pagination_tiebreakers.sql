-- =============================================================================
-- Pagination-tiebreaker audit — 105/107/108/109 RPC:er
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- BAKGRUND (2026-08-20):
--
--   ORDER 111 avslöjade att repair_abstract_targets (ORDER 109) paginerade
--   med ORDER BY coalesce(citation_count,0) DESC — icke-unik sortnyckel.
--   62 av 2 127 rader (2.9 %) förekom på TVÅ intilliggande sidor pga
--   Postgres ger ingen ordnings-garanti inom lika värden och OFFSET/LIMIT
--   plockar godtyckligt. Följd: 62 idempotenta dubbelanrop mot OpenAlex
--   och overwrite-RPC:n, samt en felräkning i repair-abstracts.md.
--
--   Denna migration auditerar samtliga 9 RPC:er som byggts idag (ORDER
--   105/107/108/109) för samma mönster: ORDER BY på icke-unik nyckel.
--   Lägger id ASC som deterministisk slutlig tiebreaker där sortnyckeln
--   inte redan är unik. Zero kostnad (id är PK, alltid indexerat), zero
--   semantisk risk (samma resultat-set, bara stabil ordning inom ties).
--
-- KATEGORISERING:
--
--   KRITISK (bug):
--     repair_abstract_targets  — paginerar (OFFSET), bevisad bugg
--
--   HÖG (liten LIMIT, deterministisk ordning användarsynlig):
--     oversikt_lead_article    — LIMIT 1 (hero-artikel byte kan förvirra)
--     spotlight_articles       — LIMIT 7 (Research Spotlight)
--     ticker_articles          — LIMIT 10 (Incoming Research-ticker)
--
--   LÅG (stor LIMIT, ingen paginering idag, framtidsdefensiv):
--     feed_articles            — LIMIT 200
--     feed_articles_by_role    — LIMIT 200
--     search_articles          — LIMIT 200
--     explore_articles         — LIMIT 100
--     map_focus_articles       — LIMIT 100
--
--   backfill_abstracts_overwrite har ingen ORDER BY (UPDATE) — inte relevant.
--
-- METOD: CREATE OR REPLACE FUNCTION med IDENTISK signatur och kropp förutom
-- ORDER BY-satsen. Ingen DROP behövs. Kropp copy-paste från ursprunglig
-- migration + `, id ASC` tillägg. GRANT och COMMENT rörs INTE (de sitter
-- kvar från ursprungliga migrationerna).
-- =============================================================================


-- =============================================================================
-- §1 KRITISK — repair_abstract_targets (ORDER 109)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.repair_abstract_targets(
  p_limit  integer DEFAULT 1000,
  p_offset integer DEFAULT 0
)
RETURNS TABLE(
  id           uuid,
  url          text,
  abstract_len integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
SET statement_timeout = '30s'
AS $fn$
  SELECT
    a.id,
    a.url,
    length(a.abstract) AS abstract_len
  FROM public.articles a
  WHERE a.abstract IS NOT NULL
    AND length(btrim(a.abstract)) > 0
    AND right(btrim(a.abstract), 1) NOT IN ('.', '!', '?', ')')
    AND (
      a.phronesis_sensory_pro         IS NOT NULL
      OR a.phronesis_culinary_pro        IS NOT NULL
      OR a.phronesis_gastronomy_culture  IS NOT NULL
      OR a.phronesis_hospitality_mgmt    IS NOT NULL
      OR a.phronesis_educator_researcher IS NOT NULL
    )
  ORDER BY coalesce(a.citation_count, 0) DESC, a.id ASC
  OFFSET p_offset
  LIMIT p_limit
$fn$;


-- =============================================================================
-- §2 HÖG — oversikt_lead_article (ORDER 108)
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
    year DESC NULLS LAST,
    fetched_at DESC,
    id ASC
  LIMIT 1
$function$;


-- =============================================================================
-- §2 HÖG — spotlight_articles (ORDER 107)
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
  ORDER BY year DESC, fetched_at DESC, id ASC
  LIMIT p_limit
$function$;


-- =============================================================================
-- §2 HÖG — ticker_articles (ORDER 107)
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
  ORDER BY year DESC NULLS LAST, id ASC
  LIMIT p_limit
$function$;


-- =============================================================================
-- §3 LÅG — feed_articles (ORDER 105)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.feed_articles(p_limit integer default 200)
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
  WHERE irrelevant IS NOT TRUE
    AND (has_episteme_sensory_pro         IS TRUE
      OR has_episteme_culinary_pro        IS TRUE
      OR has_episteme_gastronomy_culture  IS TRUE
      OR has_episteme_hospitality_mgmt    IS TRUE
      OR has_episteme_educator_researcher IS TRUE
      OR has_sci_sensory_pro              IS TRUE
      OR has_sci_culinary_pro             IS TRUE
      OR has_sci_gastronomy_culture       IS TRUE
      OR has_sci_hospitality_mgmt         IS TRUE
      OR has_sci_educator_researcher      IS TRUE)
  ORDER BY year DESC NULLS LAST, fetched_at DESC, id ASC
  LIMIT p_limit
$function$;


-- =============================================================================
-- §3 LÅG — feed_articles_by_role (ORDER 107)
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
    fetched_at DESC,
    id ASC
  LIMIT p_limit
$function$;


-- =============================================================================
-- §3 LÅG — search_articles (ORDER 108)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.search_articles(
  p_query  text,
  p_source text    DEFAULT NULL,
  p_limit  integer DEFAULT 200
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
  WITH q AS (
    SELECT
      CASE
        WHEN p_query IS NULL OR length(trim(p_query)) < 2 THEN NULL
        ELSE '%' || regexp_replace(p_query, '([\\%_])', '\\\1', 'g') || '%'
      END AS pattern
  )
  SELECT
    a.id, a.headline_en, a.title, a.topic, a.source_label, a.insight, a.limitation,
    a.study_type, a.year, a.authors, a.journal, a.url, a.knowledge_type, a.country,
    a.countries, a.keywords,
    a.relevance_sci_sensory_pro, a.relevance_sci_culinary_pro,
    a.relevance_sci_gastronomy_culture, a.relevance_sci_hospitality_mgmt,
    a.relevance_sci_educator_researcher,
    a.has_episteme_sensory_pro, a.has_episteme_culinary_pro,
    a.has_episteme_gastronomy_culture, a.has_episteme_hospitality_mgmt,
    a.has_episteme_educator_researcher,
    a.has_core_claim, a.has_imrad
  FROM public.articles_public a, q
  WHERE q.pattern IS NOT NULL
    AND a.irrelevant IS NOT TRUE
    AND (a.title    ILIKE q.pattern ESCAPE '\'
      OR a.authors  ILIKE q.pattern ESCAPE '\'
      OR a.journal  ILIKE q.pattern ESCAPE '\')
    AND (p_source IS NULL OR p_source = 'all' OR a.source_label = p_source)
  ORDER BY a.year DESC, a.id ASC
  LIMIT p_limit
$function$;


-- =============================================================================
-- §3 LÅG — explore_articles (ORDER 108)
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
    AND (
      (p_role = 'all' AND (
         has_episteme_sensory_pro         IS TRUE
      OR has_episteme_culinary_pro        IS TRUE
      OR has_episteme_gastronomy_culture  IS TRUE
      OR has_episteme_hospitality_mgmt    IS TRUE
      OR has_episteme_educator_researcher IS TRUE))
      OR
      (p_role <> 'all' AND CASE p_role
        WHEN 'sensory_pro'          THEN has_episteme_sensory_pro
        WHEN 'culinary_pro'         THEN has_episteme_culinary_pro
        WHEN 'gastronomy_culture'   THEN has_episteme_gastronomy_culture
        WHEN 'hospitality_mgmt'     THEN has_episteme_hospitality_mgmt
        WHEN 'educator_researcher'  THEN has_episteme_educator_researcher
      END IS TRUE)
    )
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


-- =============================================================================
-- §3 LÅG — map_focus_articles (ORDER 108)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.map_focus_articles(
  p_institution text,
  p_country     text,
  p_limit       integer DEFAULT 100
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
  institution_coords                jsonb,
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
    primary_institution, institution_rank, institution_coords, citation_count
  FROM public.articles_public
  WHERE (p_institution IS NOT NULL OR p_country IS NOT NULL)
    AND irrelevant IS NOT TRUE
    AND (
      (p_institution IS NOT NULL AND primary_institution = p_institution)
      OR
      (p_country IS NOT NULL AND country = p_country)
    )
  ORDER BY year DESC NULLS LAST, fetched_at DESC, id ASC
  LIMIT p_limit
$function$;


-- =============================================================================
-- SCHEMA-CACHE RELOAD
-- =============================================================================
NOTIFY pgrst, 'reload schema';


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. repair_abstract_targets ska nu ge deterministisk paginering.
--   --    Total-räkningen ska INTE ha duplicerade ids över sidor.
--   WITH pages AS (
--     SELECT id FROM public.repair_abstract_targets(1000, 0)
--     UNION ALL
--     SELECT id FROM public.repair_abstract_targets(1000, 1000)
--     UNION ALL
--     SELECT id FROM public.repair_abstract_targets(1000, 2000)
--   )
--   SELECT count(*) AS totalt, count(distinct id) AS unika
--   FROM pages;
--   -- expected: totalt = unika  (ingen id förekommer två gånger)
--
--   -- 2. Sanity — kör oversikt_lead_article två gånger, ska ge samma id.
--   SELECT id FROM public.oversikt_lead_article(
--     'culinary_pro', now() - interval '12 months');
--   SELECT id FROM public.oversikt_lead_article(
--     'culinary_pro', now() - interval '12 months');
--   -- expected: samma id båda gångerna
--
--   -- 3. Övriga RPC:er ska returnera samma antal rader som innan
--   --    (tiebreakern ändrar ordning inom ties, inte cardinality).
-- =============================================================================
