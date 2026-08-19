-- =============================================================================
-- get_screening_funnel() — RPC-wrap kring screening_funnel-vyn.
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. En push skulle försöka köra om dem. Se ORDER 091 §8.)
--
-- BAKGRUND (ORDER 098 §3, 2026-08-19):
--
--   `screening_funnel`-vyn får 500 3/5 gånger under sidladdning trots att
--   direkt curl svarar på 0.16 s solo. Fångat felsvar (via CDP
--   Network.getResponseBody, run 4/5):
--
--     {"code":"57014","message":"canceling statement due to statement timeout"}
--
--   Alltså samma 57014-familj som get_trending_keywords + get_sidebar_stats.
--   Under konkurrens från övrig sidladdning slår vyn i default statement_
--   timeout (~3 s) — troligen för att planer-cache eller shared_buffers
--   stjäls av andra tunga queryer, inte för att vyn själv är dyr.
--
--   Vyer kan inte sätta SET statement_timeout — bara funktioner och
--   roller. ALTER ROLE anon SET statement_timeout=30s valdes bort:
--   skulle ta bort skyddet mot att en tung query håller connection i
--   30 s (Anders 2026-08-19). Bättre: wrap vyn i en RPC där vi kan
--   sätta timeout scoped till just denna operation.
--
-- LÖSNING:
--
--   public.get_screening_funnel() → jsonb
--     SELECT to_jsonb(row) FROM screening_funnel LIMIT 1
--
--   jsonb för att matcha map_coverage/page_counts-parsemönstret i
--   frontenden — await r.json() ger objekt direkt, ingen array-unwrap.
--
--   Vyn returnerar alltid exakt en rad (aggregerade counters över hela
--   articles), så LIMIT 1 är säker. Skulle vyn ändras till flera rader
--   framöver får RPC:n uppdateras — men det är ändå ett arkitektur-
--   brott mot dagens användning.
--
-- BASELINE (från curl 2026-08-19):
--   {"indexerade":466905,"unika_doi":461598,"med_abstract":391886,
--    "screenade":391886,"relevanta":34637,"med_imrad":34072,
--    "triad_analyserade":34070}
--
-- VERIFIERING:
--   select public.get_screening_funnel();
--   → samma objekt som ovan (± några dagar).
--
--   Alternativt räkna key-count: select jsonb_object_keys(public.get_screening_funnel());
--   → 7 rader (indexerade, unika_doi, med_abstract, screenade, relevanta,
--                med_imrad, triad_analyserade).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_screening_funnel()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
SET statement_timeout = '30s'
AS $function$
  SELECT to_jsonb(f) FROM public.screening_funnel f LIMIT 1
$function$;

GRANT EXECUTE ON FUNCTION public.get_screening_funnel()
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.get_screening_funnel() IS
  'RPC-wrap kring screening_funnel-vyn för att kunna sätta '
  'statement_timeout=30s (vyer kan inte sätta det själva). '
  'ORDER 098 §3, 2026-08-19. Ersätter direkt fetch mot vyn som fick '
  '57014-timeout under sidladdning trots att vyn solo svarar på 0.16 s.';
