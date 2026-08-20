-- =============================================================================
-- backfill_abstracts_overwrite — reparations-RPC för trunkerade abstracts
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- BAKGRUND (ORDER 109, 2026-08-20):
--
--   Befintlig backfill_abstracts_update(p_id, p_abstract) använder
--     abstract = coalesce(abstract, p_abstract)
--   Ett kort/trunkerat abstract vinner alltid över ett nytt längre —
--   backfill-cronen rapporterar framgång utan att laga.
--
--   2 127 TRIAD-analyserade artiklar identifierade med trunkerat
--   abstract (slutar inte på . ! ? eller ")"). Att ändra coalesce-
--   logiken i den befintliga cron-RPC:n är för riskabelt: cronen
--   filtrerar på abstract IS NULL, så COALESCE är säker där — men
--   om vi ändrade den skulle nästa cron-tick börja skriva över
--   fullständiga abstracts med tomma OpenAlex-svar för rader där
--   OpenAlex inte hittar DOI.
--
-- LÖSNING: ny separat RPC med explicit overwrite-semantik.
--
--   backfill_abstracts_overwrite(p_id, p_abstract) skriver ALLTID
--   över, men bara om p_abstract inte är NULL och är minst 100
--   tecken lång efter trim. Callern (scripts/repair-abstracts.ts)
--   är ansvarig för att bara anropa RPC:n när nytt abstract är
--   LÄNGRE än befintligt — server-side-guarden är defensiv mot
--   uppenbart trasiga OpenAlex-svar (tom sträng, "N/A", enstaka
--   ord). Vidare validering hör hemma i callern.
--
--   Den gamla backfill_abstracts_update behålls oförändrad för
--   daglig cron. Dess coalesce-logik är rätt för det scenariot
--   (fyller bara NULL-rader).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.backfill_abstracts_overwrite(
  p_id       uuid,
  p_abstract text
) RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $fn$
  UPDATE public.articles SET
    abstract_attempted_at = now(),
    abstract              = p_abstract
  WHERE id = p_id
    AND p_abstract IS NOT NULL
    AND length(btrim(p_abstract)) >= 100;
$fn$;

GRANT EXECUTE ON FUNCTION public.backfill_abstracts_overwrite(uuid, text)
  TO service_role;

COMMENT ON FUNCTION public.backfill_abstracts_overwrite(uuid, text) IS
  'Reparations-RPC för trunkerade abstracts. Skriver alltid över '
  '(till skillnad från backfill_abstracts_update som använder COALESCE). '
  'Server-side-guard: p_abstract minst 100 tecken efter btrim. Callern '
  'ansvarar för längd-jämförelse mot befintligt abstract '
  '(ORDER 109, 2026-08-20).';


-- =============================================================================
-- repair_abstract_targets(p_limit, p_offset) — id-lista med paginering
-- =============================================================================
-- Skriptets fetchTargets tippade över anons 3s statement_timeout via
-- PostgREST med den or=(phronesis_… not.is.null) + not.ilike-chain-baserade
-- filterförfrågan (57014 fångad 2026-08-20). Wrap:ar samma predikat i en
-- SECURITY DEFINER-RPC med statement_timeout=30s.
--
-- Skriptet kör med service_role — GRANT ges bara dit, INTE till anon.
--
-- Predikat (exakt det som Anders verifierat i SQL-editorn = 2 127 rader):
--   abstract not null
--   AND length(trim(abstract)) > 0
--   AND right(trim(abstract),1) NOT IN ('.','!','?',')')
--   AND phronesis_<någon av 5> IS NOT NULL
--
-- Not: phronesis_<role> IS NOT NULL används som TRIAD-signal (starkare än
-- has_episteme eftersom TRIAD-pipeline skriver alla tre fält samtidigt när
-- en analys godkänns — phronesis är sista fältet som fylls).
--
-- ORDER BY coalesce(citation_count,0) DESC — reparera mest citerade först.
--
-- PAGINERING (följdfix 2026-08-20): dry-run gav 1000 rader trots p_limit
-- 3000 — Supabases PostgREST db-max-rows-cap klipper RPC-svar vid 1000
-- oavsett RPC:ns egna LIMIT. Lösning: p_offset-parameter så skriptet kan
-- iterera i sidor om 1000. p_limit default sänkt till 1000 (samma som cap:et).
--
-- SIGNATUR-BYTE: gamla 1-arg-versionen (integer) droppas explicit så inte
-- båda överlagringarna lever samtidigt.
-- =============================================================================
DROP FUNCTION IF EXISTS public.repair_abstract_targets(integer);

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
    id,
    url,
    length(abstract) AS abstract_len
  FROM public.articles
  WHERE abstract IS NOT NULL
    AND length(btrim(abstract)) > 0
    AND right(btrim(abstract), 1) NOT IN ('.', '!', '?', ')')
    AND (
      phronesis_sensory_pro         IS NOT NULL
      OR phronesis_culinary_pro        IS NOT NULL
      OR phronesis_gastronomy_culture  IS NOT NULL
      OR phronesis_hospitality_mgmt    IS NOT NULL
      OR phronesis_educator_researcher IS NOT NULL
    )
  ORDER BY coalesce(citation_count, 0) DESC
  OFFSET p_offset
  LIMIT p_limit
$fn$;

GRANT EXECUTE ON FUNCTION public.repair_abstract_targets(integer, integer)
  TO service_role;

COMMENT ON FUNCTION public.repair_abstract_targets(integer, integer) IS
  'Id-lista över trunkerade TRIAD-analyserade abstracts, paginerad. '
  'Konsumeras av scripts/repair-abstracts.ts (service_role). Predikat '
  'identiskt med SQL-verifikationen 2026-08-20 (2 127 rader). p_offset '
  'nödvändig pga PostgREST-cap på 1000 rader per RPC-svar. '
  'statement_timeout=30s (ORDER 109 följdfix, 2026-08-20).';


-- =============================================================================
-- SCHEMA-CACHE RELOAD
-- =============================================================================
NOTIFY pgrst, 'reload schema';


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--   -- RPC finns med rätt signatur
--   select proname, pronargs from pg_proc
--    where pronamespace = 'public'::regnamespace
--      and proname     = 'backfill_abstracts_overwrite';
--   -- expected: 1 row, pronargs=2
--
--   -- service_role kan köra, anon INTE
--   select has_function_privilege('service_role',
--     'public.backfill_abstracts_overwrite(uuid,text)','EXECUTE');
--   -- expected: t
--   select has_function_privilege('anon',
--     'public.backfill_abstracts_overwrite(uuid,text)','EXECUTE');
--   -- expected: f
--
--   -- Guard mot kort text: no-op (0 rader uppdaterade)
--   select public.backfill_abstracts_overwrite(
--     '00000000-0000-0000-0000-000000000000'::uuid, 'kort');
--   -- expected: void, ingen rad rörd
--
--   -- Guard mot NULL: no-op
--   select public.backfill_abstracts_overwrite(
--     '00000000-0000-0000-0000-000000000000'::uuid, NULL);
--   -- expected: void, ingen rad rörd
-- =============================================================================
