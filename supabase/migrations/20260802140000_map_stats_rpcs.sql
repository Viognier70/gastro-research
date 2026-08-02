-- =============================================================================
-- map_institution_stats() + map_country_stats() — server-side aggregering
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- BAKGRUND:
--
--   PostgREST db-max-rows = 1000 på detta projekt. Bekräftat 2026-08-02:
--
--     await sb.from('articles_public').select(...).limit(30000)
--     → data: Array(1000), status: 200, error: null
--
--   Servern kapar tyst vid 1 000 rader oavsett vad klienten begär, och den
--   klientsidiga console.warn-check jag byggde (mot limit=30000) triggar
--   aldrig. Kartans client-side aggregering av 38 897 articles var därmed
--   omöjlig — 1 000 av populationen ger Sverige 1 dot i stället för 10.
--
--   Tredje gången samma tak biter i veckan: författar-backfillen (PostgREST-
--   filter som tyst släpptes), authors-backfillens första skarpa körning
--   (limit=1000 på PATCH-populationen), och nu kartan. Se docs/postgrest-
--   caps.md för generell notering.
--
-- LÖSNING:
--
--   Två RPC:er som aggregerar i SQL och returnerar JSONB (en rad — bypass
--   av 1 000-cappen som gäller per row, inte per fält). Frontend slår i
--   O(1) mot dict:et som byggs från svaret.
--
-- UNIVERSUM:
--
--   irrelevant is not true (matchar articles_public exponerings-gate)
--   primary_institution is not null (räkning kräver attribuering)
--
--   INGEN TRIAD-gate på räknarna — sidbaren räknar 33 för Örebro (all
--   primary_institution-produktion), inte 10 (bara TRIAD-analyserad).
--   Coverage-copyn har SIN egen TRIAD-gate via head-count-queries, det
--   är en separat "hur långt har vi kommit"-metric.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- map_institution_stats() — [{institution, country, article_count}, ...]
-- ---------------------------------------------------------------------------
-- Grupperar på primary_institution. Country per institution via mode()
-- (mest förekommande country-code); safe eftersom country = countries[0]
-- verifierats identisk i 32 760 rader (2026-08-02, 0 avvikelser).
-- Undantag: institutioner utan primary_institution-räkning men med
-- coord-entry filtreras bort — de 630 sådana rader har ingen tydlig
-- ägare och räknas inte per spec-diskussion 2026-08-02.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.map_institution_stats()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'institution',   primary_institution,
        'country',       country,
        'article_count', c
      )
    ),
    '[]'::jsonb
  )
  from (
    select
      primary_institution,
      mode() within group (order by country) as country,
      count(*)::int as c
    from public.articles
    where irrelevant is not true
      and primary_institution is not null
    group by primary_institution
  ) t
$function$;

grant execute on function public.map_institution_stats() to anon, authenticated, service_role;


-- ---------------------------------------------------------------------------
-- map_country_stats() — [{country, article_count, institution_count}, ...]
-- ---------------------------------------------------------------------------
-- Grupperar på articles.country. Ingen dubbelräkning — count(distinct id)
-- är implicit via GROUP BY country på en icke-arrayad kolumn. Distinct-
-- primary_institution ger antalet unika institutioner i landet (inte
-- bara de coord-havande — sidbarens listade dots är ett subset).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.map_country_stats()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'country',           country,
        'article_count',     article_count,
        'institution_count', institution_count
      )
    ),
    '[]'::jsonb
  )
  from (
    select
      country,
      count(*)::int as article_count,
      count(distinct primary_institution)::int as institution_count
    from public.articles
    where irrelevant is not true
      and country is not null
      and primary_institution is not null
    group by country
  ) t
$function$;

grant execute on function public.map_country_stats() to anon, authenticated, service_role;


-- =============================================================================
-- Verifiering (efter apply):
--
--   -- Storlek:
--   select jsonb_array_length(public.map_institution_stats());
--   -- expected: ~5-10k (unika primary_institution med minst 1 non-irrelevant)
--
--   select jsonb_array_length(public.map_country_stats());
--   -- expected: ~80-120 country-koder
--
--   -- Örebro (baseline 2026-08-02: 28 med primary = 'Örebro University'):
--   select value from jsonb_array_elements(public.map_institution_stats())
--    where value->>'institution' = 'Örebro University';
--   -- expected: {"institution":"Örebro University","country":"SE","article_count":28}
--
--   -- Grants:
--   select has_function_privilege('anon',
--     'public.map_institution_stats()', 'EXECUTE');   -- expect true
--   select has_function_privilege('anon',
--     'public.map_country_stats()', 'EXECUTE');       -- expect true
-- =============================================================================
