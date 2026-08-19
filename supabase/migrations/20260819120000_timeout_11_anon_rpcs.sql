-- =============================================================================
-- statement_timeout + search_path på återstående 10 anon-anropbara RPC:er
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. En push skulle försöka köra om dem. Se ORDER 091 §8.)
--
-- BAKGRUND (ORDER 099, 2026-08-19):
--
--   ORDER 096/097b/098 fixade 500-stormen ner till 0 konsekventa. Kvar
--   är en klass RPC:er som saknar statement_timeout och är anropbara
--   av anon — dvs kan träffa samma 57014-timeout under load. Bättre
--   proaktivt än reaktivt.
--
-- METOD: ALTER FUNCTION istället för CREATE OR REPLACE.
--
--   ORDER 099 begärde pg_get_functiondef + CREATE OR REPLACE med
--   "EXAKT befintlig kropp och signatur ... skriv inte om logiken".
--   ALTER FUNCTION SET uppfyller det kravet ännu strängare: kroppen
--   rörs INTE ALLS. Postgres uppdaterar bara funktionens config
--   (proconfig-kolumnen i pg_proc), aldrig prosrc.
--
--   Ingen risk för copy-paste-fel. Ingen risk att missa ett
--   trailing whitespace, en $function$-quote-nivå, eller en
--   dollar-quoted body med inbäddade dollartecken.
--
-- SCOPE (10 funktioner):
--
-- §1 — karta (7 st, redan har search_path — bara timeout):
--   map_country_stats()
--   map_institution_collabs()
--   map_institution_coords()
--   map_institution_detail(p_name text)
--   map_institution_stats()
--   map_institutions_by_keyword(p_keyword text)
--   knowledge_map_topics()
--
-- §2 — övriga anon-RPC:er (3 st, saknar även search_path):
--   get_synthesis_stats()
--   match_articles(vector, double precision, integer)
--   match_related(uuid, integer, double precision)
--
-- BASELINE: karta-vyn har aldrig auditerats separat. ORDER 099-rapporten
-- ska mäta /?view=map efter denna migration körts.
-- =============================================================================

-- §1: map-familjen (search_path finns, bara timeout)
ALTER FUNCTION public.map_country_stats()
  SET statement_timeout = '30s';

ALTER FUNCTION public.map_institution_collabs()
  SET statement_timeout = '30s';

ALTER FUNCTION public.map_institution_coords()
  SET statement_timeout = '30s';

ALTER FUNCTION public.map_institution_detail(p_name text)
  SET statement_timeout = '30s';

ALTER FUNCTION public.map_institution_stats()
  SET statement_timeout = '30s';

ALTER FUNCTION public.map_institutions_by_keyword(p_keyword text)
  SET statement_timeout = '30s';

ALTER FUNCTION public.knowledge_map_topics()
  SET statement_timeout = '30s';

-- §2: övriga anon-RPC:er (behöver även search_path)
ALTER FUNCTION public.get_synthesis_stats()
  SET statement_timeout = '30s',
  SET search_path       = public, pg_temp;

ALTER FUNCTION public.match_articles(vector, double precision, integer)
  SET statement_timeout = '30s',
  SET search_path       = public, pg_temp;

ALTER FUNCTION public.match_related(uuid, integer, double precision)
  SET statement_timeout = '30s',
  SET search_path       = public, pg_temp;

-- =============================================================================
-- VERIFIERING (bör returnera 10 rader, alla med statement_timeout=30s):
--
-- SELECT p.proname,
--        p.proconfig
-- FROM pg_proc p
-- JOIN pg_namespace n ON n.oid = p.pronamespace
-- WHERE n.nspname = 'public'
--   AND p.proname IN (
--     'map_country_stats','map_institution_collabs','map_institution_coords',
--     'map_institution_detail','map_institution_stats',
--     'map_institutions_by_keyword','knowledge_map_topics',
--     'get_synthesis_stats','match_articles','match_related'
--   )
-- ORDER BY p.proname;
-- =============================================================================
