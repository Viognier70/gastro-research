-- =============================================================================
-- match_related — SECURITY DEFINER + search_path + statement_timeout
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- BAKGRUND (ORDER 130, 2026-08-22):
--
--   match_related är LANGUAGE plpgsql STABLE utan SECURITY DEFINER
--   (senaste omskrivningen: 20260731120000). Anon och authenticated har
--   EXECUTE på fn:en men saknar SELECT på articles — när fn:en kör läser
--   den articles.embedding som anropande roll och får 42501 permission
--   denied. loadRelated i artikelöverlägget (index.html ~5134, Pro-only)
--   fångar felet tyst → grannlistan har aldrig renderats i produktion.
--
--   Fix: samma pattern som RPC-auditen 2026-08-19..20 — SECURITY DEFINER
--   med hardened search_path + statement_timeout, och REVOKE FROM public
--   som hygien.
--
-- SÄKERHETSGRANSKNING AV RETURN-KOLUMNER (punkt 2 i ordern):
--
--   RETURNS TABLE(id uuid, title text, journal text, year text,
--                 similarity double precision)
--
--   Ingen TRIAD, inga has_*-booleaner, ingen abstract, ingen author,
--   ingen affiliation, ingen evidence_type. Bara metadata-fem som
--   redan exponeras via articles_public-vyn för anon utan påslag.
--   SECURITY DEFINER är därför INGEN läcka — kolumnlistan är redan
--   begränsad. Om fn:en i framtiden utökas med fler kolumner måste
--   detta ta-om-utvärderas — TRIAD-fält från articles bakom DEFINER
--   är exakt läckan get_articles_full skyddar mot genom Pro-gaten.
--
-- HNSW-OPTIMERINGEN BEVARAS EXAKT:
--
--   Kroppen är oförändrad från 20260731120000 — samma seed-variabel
--   för konstant vektor, samma p_k * 3 headroom, samma outer-filter.
--   Bara CREATE OR REPLACE-header och privilege-modell ändras.
--   HNSW-planen (Index Scan using idx_articles_embedding_hnsw) står
--   kvar; verifiera med explain analyze i steg 2 nedan.
-- =============================================================================


CREATE OR REPLACE FUNCTION public.match_related(
  p_article_id uuid,
  p_k          int   DEFAULT 10,
  p_floor      float DEFAULT 0.70
)
RETURNS TABLE(
  id         uuid,
  title      text,
  journal    text,
  year       text,
  similarity double precision
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
SET statement_timeout = '30s'
AS $function$
DECLARE
  v_seed vector(1536);
BEGIN
  select embedding
    into v_seed
    from public.articles
   where id = p_article_id
     and embedding is not null;

  if v_seed is null then
    return;
  end if;

  return query
  with topk as (
    select
      a.id,
      a.title,
      a.journal,
      a.year,
      a.irrelevant,
      1 - (a.embedding <=> v_seed) as sim
    from public.articles a
    where a.embedding is not null
    order by a.embedding <=> v_seed
    limit p_k * 3
  )
  select t.id, t.title, t.journal, t.year, t.sim
    from topk t
   where t.id <> p_article_id
     and t.irrelevant is not true
     and t.sim > p_floor
   order by t.sim desc
   limit p_k;
END;
$function$;


-- =============================================================================
-- Grants — DEFINER-fn ska inte ligga öppen för PUBLIC. Explicit whitelista
-- anon, authenticated, service_role (samma set som föregående migration).
-- =============================================================================
REVOKE ALL ON FUNCTION public.match_related(uuid, int, float) FROM public;
GRANT EXECUTE ON FUNCTION public.match_related(uuid, int, float)
  TO anon, authenticated, service_role;


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Fn:en är nu DEFINER + har rätt search_path + timeout
--   SELECT proname, prosecdef, proconfig
--     FROM pg_proc
--    WHERE proname='match_related'
--      AND pronamespace='public'::regnamespace;
--   -- expected: prosecdef=t, proconfig innehåller
--   --           {search_path=public, pg_temp, statement_timeout=30s}
--
--   -- 2. HNSW-planen är kvar
--   EXPLAIN ANALYZE
--     SELECT * FROM public.match_related(
--       (SELECT id FROM public.articles WHERE embedding IS NOT NULL LIMIT 1),
--       10, 0.70);
--   -- expected: "Index Scan using idx_articles_embedding_hnsw" i planen,
--   --           total tid < 100 ms
--
--   -- 3. Rök-test som anon (kör i SQL editor med SET ROLE anon;)
--   SET LOCAL ROLE anon;
--   SELECT count(*) FROM public.match_related(
--     (SELECT id FROM public.articles WHERE embedding IS NOT NULL LIMIT 1),
--     10, 0.70);
--   RESET ROLE;
--   -- expected: > 0 (tidigare: 42501 permission denied for table articles)
-- =============================================================================
