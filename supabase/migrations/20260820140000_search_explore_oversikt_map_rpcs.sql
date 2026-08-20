-- =============================================================================
-- search_articles / explore_articles / oversikt_lead_article / map_focus_articles
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- BAKGRUND (ORDER 108, 2026-08-20):
--
--   Avslutar RPC-auditen efter ORDER 105/107. Fem direktfetches
--   mot articles_public utan RPC-wrap kvarstod. Curl-mätning
--   2026-08-20:
--     Q1 SEARCH (ilike × 3 kolumner)  500 vid cold cache, 3.26s ⚠
--     Q2 EXPLORE role-specifik        0.21–0.59s (låg risk)
--     Q3 EXPLORE role='all'           0.19–0.60s (låg risk)
--     Q4 OVERSIKT-lead                0.45–1.18s (marginal)
--     Q5 MAP-focus                    0.41–1.48s (marginal)
--
--   SEARCH är den enda med bekräftad 500 — men samtliga fyra
--   byggs för konsistens (samma mönster som ORDER 107) så
--   audit-arbetet avslutas i en omgång.
--
-- SÄKERHET: p_role via CASE + WHERE-guard, aldrig strängkonkatenering.
--
--   Samma mönster som ORDER 107. explore_articles hanterar även
--   p_role='all' via specialfall i WHERE-uttrycket — ingen separat
--   RPC behövs (frontend har både grenar idag, ORDER 108-specen
--   ber om EN RPC per callsite).
--
-- SÄKERHET: search_articles p_query LIKE-eskapering.
--
--   Frontend skickar rå söksträng till PostgREST via url-encoded
--   ilike-parameter. `%`, `_` och `\` behandlas som LIKE-metatecken
--   → en användare som söker "50%" får alla artiklar där text
--   innehåller "50" följt av vad som helst. RPC:n eskapierar
--   metatecknen med regexp_replace innan de går in i ILIKE-pattern.
--   ESCAPE '\' är explicit för att inte förlita sig på Postgres
--   default (samma i praktiken men läses tydligare).
-- =============================================================================

-- =============================================================================
-- §1 — search_articles(p_query, p_source, p_limit)
--   Ersätter loadArticles sök-mode (index.html ~3282).
--   Predikat: title/authors/journal ILIKE '%<eskaperad p_query>%'
--             + optional source=eq.<p_source>
--   Sortering: year desc
--   Rollagnostisk (search visar över alla roller).
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
    -- Eskapera LIKE-metatecken \ % _ i användarens söksträng innan de
    -- omsluts av jokrar. regexp_replace matchar en enskild kolumn ur
    -- character class [\\%_] och prefixar med backslash. Ordningen på
    -- klass-innehållet är oviktig — men \\ måste komma först i replace-
    -- strängen (\\\1 = backslash + captured char).
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
  ORDER BY a.year DESC
  LIMIT p_limit
$function$;

GRANT EXECUTE ON FUNCTION public.search_articles(text, text, integer)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.search_articles(text, text, integer) IS
  'Feed sök-mode. Ersätter direktfetch mot articles_public i loadArticles '
  '(index.html) när search.length > 1. LIKE-metatecken eskaperas server-'
  'side. statement_timeout=30s (ORDER 108, 2026-08-20).';


-- =============================================================================
-- §2 — explore_articles(p_role, p_topic, p_limit)
--   Ersätter loadExploreArticles (index.html ~4398 + ~4401).
--   Hanterar BÅDE role='all' OCH role='specifik' i EN RPC.
--   Predikat role='all':      or(has_episteme_<role>) över 5 roller + topic=p_topic
--   Predikat role='specifik': has_episteme_<role>=true + topic=p_topic
--   Sortering role='all':     year desc nulls last, fetched_at desc
--   Sortering role='specifik':relevance_sci_<role> desc nulls last, fetched_at desc
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
      -- role='all': 5-vägs OR över alla has_episteme
      (p_role = 'all' AND (
         has_episteme_sensory_pro         IS TRUE
      OR has_episteme_culinary_pro        IS TRUE
      OR has_episteme_gastronomy_culture  IS TRUE
      OR has_episteme_hospitality_mgmt    IS TRUE
      OR has_episteme_educator_researcher IS TRUE))
      OR
      -- role='specifik': bara den rollens has_episteme
      (p_role <> 'all' AND CASE p_role
        WHEN 'sensory_pro'          THEN has_episteme_sensory_pro
        WHEN 'culinary_pro'         THEN has_episteme_culinary_pro
        WHEN 'gastronomy_culture'   THEN has_episteme_gastronomy_culture
        WHEN 'hospitality_mgmt'     THEN has_episteme_hospitality_mgmt
        WHEN 'educator_researcher'  THEN has_episteme_educator_researcher
      END IS TRUE)
    )
  ORDER BY
    -- Primärsort för role='specifik': relevance_sci_<role> desc.
    -- role='all': CASE ger NULL för alla rader → same bucket → passeras.
    CASE p_role
      WHEN 'sensory_pro'          THEN relevance_sci_sensory_pro
      WHEN 'culinary_pro'         THEN relevance_sci_culinary_pro
      WHEN 'gastronomy_culture'   THEN relevance_sci_gastronomy_culture
      WHEN 'hospitality_mgmt'     THEN relevance_sci_hospitality_mgmt
      WHEN 'educator_researcher'  THEN relevance_sci_educator_researcher
    END DESC NULLS LAST,
    -- Primärsort för role='all': year desc. role='specifik': NULL → same
    -- bucket → passeras. Två CASE istället för mixed-type-uttryck eftersom
    -- year är text och relevance_sci är integer.
    CASE WHEN p_role = 'all' THEN year END DESC NULLS LAST,
    fetched_at DESC
  LIMIT p_limit
$function$;

GRANT EXECUTE ON FUNCTION public.explore_articles(text, text, integer)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.explore_articles(text, text, integer) IS
  'Explore-per-topic. Ersätter direktfetch mot articles_public i '
  'loadExploreArticles (index.html). Hanterar både role=all och '
  'role=specifik i EN RPC. statement_timeout=30s (ORDER 108, 2026-08-20).';


-- =============================================================================
-- §3 — oversikt_lead_article(p_role, p_since)
--   Ersätter renderOversiktLead (index.html ~6109).
--   Predikat: has_episteme_<role>=true OR has_sci_<role>=true
--             + fetched_at >= p_since (cutoff, ~12 månader)
--   Sortering: relevance_sci_<role> desc nulls last, year desc nulls last,
--              fetched_at desc
--   Limit fixerat 1 (frontend hämtar alltid en ledande artikel).
--   Kolumner: relevance_sci aliaserad från relevance_sci_<role>.
--   has_episteme/has_sci behövs inte i returtypen (frontend läser inte).
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
    fetched_at DESC
  LIMIT 1
$function$;

GRANT EXECUTE ON FUNCTION public.oversikt_lead_article(text, timestamptz)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.oversikt_lead_article(text, timestamptz) IS
  'Overview lead-artikel. Ersätter direktfetch i renderOversiktLead '
  '(index.html). relevance_sci aliaserad från relevance_sci_<role>. '
  'statement_timeout=30s (ORDER 108, 2026-08-20).';


-- =============================================================================
-- §4 — map_focus_articles(p_institution, p_country, p_limit)
--   Ersätter loadMapFocusArticles (index.html ~7430).
--   Predikat: (p_institution = primary_institution) OR (p_country = country)
--             — frontend skickar EN av dem, aldrig båda. Guard mot båda NULL.
--   Sortering: year desc nulls last, fetched_at desc
--   Rollagnostisk (map visar institutionens/landets hela output).
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
  ORDER BY year DESC NULLS LAST, fetched_at DESC
  LIMIT p_limit
$function$;

GRANT EXECUTE ON FUNCTION public.map_focus_articles(text, text, integer)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.map_focus_articles(text, text, integer) IS
  'Map focus-artiklar. Ersätter direktfetch i loadMapFocusArticles '
  '(index.html). Antingen p_institution eller p_country, aldrig båda. '
  'statement_timeout=30s (ORDER 108, 2026-08-20).';


-- =============================================================================
-- SCHEMA-CACHE RELOAD
-- =============================================================================
NOTIFY pgrst, 'reload schema';


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   select count(*) from public.search_articles('wine', null, 200);
--   -- expected: 0–200
--
--   -- LIKE-metatecken ska INTE trigga wildcard-matchning:
--   select count(*) from public.search_articles('50%', null, 200);
--   -- expected: 0 (om ingen artikel har literal "50%" i title/authors/journal)
--
--   -- Kort query ska ge 0 rader (matchar frontend search.length > 1):
--   select count(*) from public.search_articles('a', null, 200);
--   -- expected: 0
--
--   select count(*) from public.explore_articles('culinary_pro', 'hospitality', 100);
--   -- expected: 0–100
--   select count(*) from public.explore_articles('all', 'hospitality', 100);
--   -- expected: 0–100
--
--   -- Ogiltig roll ska ge 0 rader:
--   select count(*) from public.explore_articles('robert''; DROP TABLE x;--', 'hospitality', 100);
--   -- expected: 0
--
--   select count(*) from public.oversikt_lead_article('culinary_pro', now() - interval '12 months');
--   -- expected: 0 eller 1
--   select count(*) from public.oversikt_lead_article('culinary_pro', null);
--   -- expected: 0 (p_since IS NOT NULL-guard)
--
--   select count(*) from public.map_focus_articles('University of Missouri', null, 100);
--   -- expected: 0–100
--   select count(*) from public.map_focus_articles(null, 'US', 100);
--   -- expected: 0–100
--   select count(*) from public.map_focus_articles(null, null, 100);
--   -- expected: 0 (båda-null-guard)
-- =============================================================================
