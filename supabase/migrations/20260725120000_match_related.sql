-- =============================================================================
-- match_related — pgvector-grannar för en given artikel (top-K, floor 0.70)
-- =============================================================================
-- Bakgrund:
--
--   Ramar in TRIAD-analysen som "vad DEN HÄR artikeln gör anspråk på" genom
--   att exponera 10–25 närmaste ämnesgrannar under analysen. Läsaren kan
--   själv bedöma anspråket mot närliggande forskning — vilket är billigare
--   och ärligare än att köra om 33 048 TRIAD-analyser mot Claude 4 för $422.
--
--   Mätt underlag (2026-07-25, två artiklar × 25 grannar):
--     - Havreyoghurt (tätt ämne): 0.7445 → 0.6783, alla 25 relevanta
--     - Getost/kvalster (nischat): 0.8552 → 0.7118, alla 25 relevanta
--     - Båda planar ut kring 0.71 → golv 0.70 binder inte på normala ämnen
--       men skyddar mot verkligt tunna där även topp-K skulle vara skräp.
--
-- APPLICERA MANUELLT I SQL-EDITORN — INTE VIA `supabase db push`.
--
--   content_gating.sql (20260704120000) refererar chip-slug-kolumner
--   (relevance_sci_sommelier m.fl.) som droppas senare i migrations-
--   kedjan (20260713140100_articles_drop_legacy_chip_cols.sql). Fresh
--   replay från början är därför trasig. Anders applicerar denna
--   funktionskropp manuellt. Filen finns för git-paritet.
--
-- Val och avgränsningar:
--
--   1. INGEN SECURITY DEFINER. Articles har en permissiv RLS-policy
--      "Public can read articles" (qual=true) för anon — verifierat
--      2026-07-25. Därför räcker LANGUAGE sql STABLE (invoker) för att
--      match_related ska returnera rader till anon, precis som
--      match_articles gör. En tidigare läsning av content_gating.sql
--      Section 3 antydde motsatsen (ingen anon-policy) men reality
--      divergerade från den intentionen. Utan DEFINER slipper vi också
--      SET search_path-frågan.
--
--   2. Filter först, sedan order+limit (samma mönster som match_articles):
--      similarity > p_floor → order → limit p_k. Tunna ämnen får färre än
--      p_k grannar hellre än att fylla med skräp.
--
--   3. irrelevant is not true — samma filter som match_articles fick igår
--      (20260724120000). 4 461 skräpvektorer har embedding men markerades
--      irrelevant efter att embedding skrevs.
--
--   4. Self-exclusion via a.id <> p_article_id. Utan detta hamnar artikeln
--      själv alltid på plats 1 (similarity = 1.0) och äter en av p_k platser.
--
--   5. Vektorrang ≠ evidentiell närhet. Grannen som mest direkt prövar
--      samma ingrepp kan ligga längre ner än en generisk metodstudie. Detta
--      är medvetet backloggat — Sonnet-omrankning är en egen funktion, inte
--      del av den här RPC:n.
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
LANGUAGE sql
STABLE
AS $function$
  with seed as (
    select embedding
    from articles
    where id = p_article_id
      and embedding is not null
  )
  select
    a.id,
    a.title,
    a.journal,
    a.year,
    1 - (a.embedding <=> seed.embedding) as similarity
  from articles a
  cross join seed
  where a.id <> p_article_id
    and a.irrelevant is not true
    and a.embedding is not null
    and 1 - (a.embedding <=> seed.embedding) > p_floor
  order by a.embedding <=> seed.embedding
  limit p_k;
$function$;


-- =============================================================================
-- Grants — samma mönster som match_articles/get_role_centroid: alla tre
-- roller får EXECUTE. Även om anon-frontenden är primär anropare vill vi
-- inte att en framtida edge-fn får överraskande permission-denied.
-- =============================================================================

grant execute on function public.match_related(uuid, int, float) to anon, authenticated, service_role;
