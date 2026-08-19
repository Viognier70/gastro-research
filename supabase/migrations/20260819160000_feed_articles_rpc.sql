-- =============================================================================
-- feed_articles() — 28-kolumners Feed-läsning med statement_timeout
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- BAKGRUND (ORDER 105, 2026-08-19):
--
--   Feed-fetchen (index.html ~rad 3311, role='all'-grenen) läste
--   articles_public direkt med 28 kolumner + 10-vägs or() över
--   has_episteme_<role> och has_sci_<role> + irrelevant=is.false +
--   order year.desc.nullslast, fetched_at.desc + limit 200. Från
--   browsern timeoutade den med 57014 efter 3.03 s (Envoy log:
--   x-envoy-upstream-service-time: 3031). anons default
--   statement_timeout är ~3 s.
--
--   Symptom i UI: "0 articles filtered for your role" — det tomma
--   svaret gjorde att renderFeed() gav tomma listor även för användare
--   som INTE hade role='all' (feed-count-rendering föll tillbaka på
--   fel default).
--
-- LÖSNING:
--
--   Wrap:a den tunga role='all'-varianten i en SECURITY DEFINER RPC
--   med statement_timeout=30s. Predikatet, sorteringen och kolumnerna
--   är IDENTISKA med dagens fetch. Ingen förändring av semantik.
--
--   role='specifikt'-grenen (2-vägs or över has_episteme_<role> +
--   has_sci_<role>) berörs inte här — den kör fortfarande direkt mot
--   articles_public och skalar bättre eftersom OR-listan är kort.
--
-- RETURTYP: RETURNS TABLE(...) med 28 explicita kolumner.
--
--   Motivering: PostgREST hanterar `RETURNS TABLE(...)` deterministiskt
--   som en resultat-tabell — klienten får en array med objekt (samma
--   shape som direkt `select` från vy). `RETURNS setof articles_public`
--   är sköre eftersom articles_public är en VIEW, och PostgREST-
--   beteendet med setof <view> är mindre garanterat. TABLE ger också
--   explicit signatur som fångar upp om vy-schemat drifter — då
--   krasar RPC:n synligt istället för att tyst leverera fel data.
--
-- ORDER 105 SIGNATUR: feed_articles(p_limit integer default 200).
--   Ingen p_role / p_topic / p_source. Frontend anropar RPC:n bara
--   när role='all' AND topic='all' AND src='all' — övriga filter-
--   kombinationer kör kvar direkt mot articles_public (mindre OR-
--   listor, timeoutar sällan).
--
-- VERIFIERING EFTER APPLY:
--   select count(*) from public.feed_articles(200);
--   -- expected: 200 (limit-taket) på ett normal-läge
--   select count(*) from public.feed_articles(10);
--   -- expected: 10
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
  ORDER BY year DESC NULLS LAST, fetched_at DESC
  LIMIT p_limit
$function$;

GRANT EXECUTE ON FUNCTION public.feed_articles(integer)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.feed_articles(integer) IS
  'Feed-läsning för role=all-läget. 28 kolumner, 10-vägs OR över '
  'has_episteme_/has_sci_-booleans, order year/fetched_at desc, limit p_limit. '
  'Wrap kring articles_public för att sätta statement_timeout=30s — anon-'
  'defaultens ~3s klippte queryen (ORDER 105, 2026-08-19).';
