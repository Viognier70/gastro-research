-- =============================================================================
-- get_sidebar_stats — lägg statement_timeout + search_path
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. En push skulle försöka köra om dem. Se ORDER 091 §8.)
--
-- BAKGRUND (ORDER 098 §1, 2026-08-19):
--
--   Efter ORDER 097b sjönk 500-stormen från 11 till 2 konsekventa.
--   get_sidebar_stats är en av två som fortfarande 500:ar 3/3 körningar.
--
--   Direkt curl: 2.5 s → 200 (cold cache råkade landa under gränsen).
--   Från browsern under övrig load: 500 (över gränsen).
--
--   Samma symptom och samma orsak som get_trending_keywords innan
--   ORDER 096 §1: två count-aggregeringar över hela articles-tabellen
--   (topic + journal, båda GROUP BY + ORDER BY) utan
--   SET statement_timeout — ärver anon-rollens default (~3 s).
--
-- LÖSNING:
--
--   CREATE OR REPLACE med samma logik + boilerplate från
--   get_trending_keywords / map_coverage / page_counts:
--     SET search_path = public, pg_temp
--     SET statement_timeout = '30s'
--   + STABLE + explicit GRANT.
--
--   Kroppen oförändrad — samma json_build_object med topics + journals.
--
-- VERIFIERING:
--   select public.get_sidebar_stats();
--   → {"topics":[...20 rader...], "journals":[...30 rader...]}
--   Ingen HTTP 500 från browsern.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_sidebar_stats()
RETURNS json
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
SET statement_timeout = '30s'
AS $function$
  SELECT json_build_object(
    'topics', (
      SELECT json_agg(row_to_json(t)) FROM (
        SELECT topic AS "0", count(*) AS "1" FROM articles
        WHERE topic IS NOT NULL GROUP BY topic ORDER BY count(*) DESC LIMIT 20
      ) t
    ),
    'journals', (
      SELECT json_agg(row_to_json(j)) FROM (
        SELECT journal AS "0", count(*) AS "1" FROM articles
        WHERE journal IS NOT NULL AND journal <> ''
        GROUP BY journal ORDER BY count(*) DESC LIMIT 30
      ) j
    )
  )
$function$;

GRANT EXECUTE ON FUNCTION public.get_sidebar_stats()
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.get_sidebar_stats() IS
  'Topic- och journal-count till sidopanelen. ORDER 098 §1: lade '
  'statement_timeout=30s + search_path för att stoppa 57014-timeouts '
  'under sidladdning. Original-definition från '
  '20260716120000_adopt_orphan_rpcs.sql.';
