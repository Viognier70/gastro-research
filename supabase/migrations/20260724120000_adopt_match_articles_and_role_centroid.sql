-- =============================================================================
-- Adoptera match_articles + get_role_centroid (patchade i prod 2026-07-24)
-- =============================================================================
-- Båda funktionerna är patchade DIREKT mot prod-DB idag och verifierade (fem
-- roller ger 54 unika av 60 träffplatser). Denna migration är för git-paritet
-- — definitionerna är redan live, kör INTE mot prod.
--
-- BAKGRUND:
--
--   1. match_articles saknade `irrelevant is not true`-filter → 4 461
--      skräpvektorer smugit in i similarity-sökningen (embeddings finns även
--      på artiklar som markerats irrelevant efter att embedding skrevs).
--      Buggen har flödat till både semantic-search och ask-synth sedan
--      irrelevant-populationen växte i juli.
--
--   2. get_role_centroid refererade `relevance_sci_sommelier` (och 4 andra
--      chip-slug-kolumner) som droppades 2026-07-13 i
--      20260713140100_articles_drop_legacy_chip_cols.sql. Sedan dess har
--      funktionen kastat 42703 (undefined column) vid VARJE anrop för ALLA
--      roller. Buggen var osynlig i git eftersom funktionen aldrig legat
--      där — samma lärdom-7-population som get_most_cited hade
--      (adopterad i 20260716120000_adopt_orphan_rpcs.sql).
--
--   3. ELSE-grenen ger nu `false` i stället för sensory_pro-fallback →
--      okända rollnamn returnerar NULL (via `avg() where false`) i stället
--      för att tyst leverera sensory_pro-centroiden till en anropare som
--      trodde den fick något annat. Anrop av get_role_centroid är inte i
--      git (grep 2026-07-24, noll träffar) — antingen orphan-RPC som ännu
--      inte adopterats, död kod, eller anrop från SQL Editor / Python-jobb.
--      Om anropare finns och de förutsatte fallback: de bryts nu, men det
--      är signalen som varit dold.
--
-- create or replace, INTE drop + create — drop tar med sig granten.
-- =============================================================================


-- =============================================================================
-- 1. get_role_centroid — genomsnittsvektor för alla artiklar med relevans ≥7
--    för given roll. Används för roll-rankad landskaps-projektion / semantic-
--    filter. Ordagrann prod-definition per 2026-07-24.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_role_centroid(p_role text)
 RETURNS vector
 LANGUAGE sql
 STABLE
AS $function$
  select avg(embedding)::vector(1536)
  from articles
  where embedding is not null
    and irrelevant is not true
    and case p_role
      when 'sensory_pro'         then relevance_sci_sensory_pro         >= 7
      when 'culinary_pro'        then relevance_sci_culinary_pro        >= 7
      when 'educator_researcher' then relevance_sci_educator_researcher >= 7
      when 'gastronomy_culture'  then relevance_sci_gastronomy_culture  >= 7
      when 'hospitality_mgmt'    then relevance_sci_hospitality_mgmt    >= 7
      else false
    end;
$function$;


-- =============================================================================
-- 2. match_articles — pgvector-similarity-sök över articles.embedding.
--    Kallas från supabase/functions/semantic-search/index.ts:113 och
--    supabase/functions/ask-synth/index.ts:161. Ordagrann prod-definition
--    per 2026-07-24 (nu med irrelevant-filter).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_articles(query_embedding vector, match_threshold double precision DEFAULT 0.5, match_count integer DEFAULT 10)
 RETURNS TABLE(id uuid, title text, core_claim text, journal text, year text, topic text, similarity double precision)
 LANGUAGE sql
 STABLE
AS $function$
  select
    a.id, a.title, a.core_claim, a.journal, a.year, a.topic,
    1 - (a.embedding <=> query_embedding) as similarity
  from articles a
  where a.embedding is not null
    and a.irrelevant is not true
    and 1 - (a.embedding <=> query_embedding) > match_threshold
  order by a.embedding <=> query_embedding
  limit match_count;
$function$;


-- =============================================================================
-- Grants — anon/authenticated/service_role har EXECUTE på båda i prod
-- (verifierat 2026-07-24 med has_function_privilege). Explicita grants så
-- fresh replay ger samma resultat.
-- =============================================================================

grant execute on function public.match_articles(vector, double precision, integer) to anon, authenticated, service_role;
grant execute on function public.get_role_centroid(text) to anon, authenticated, service_role;
