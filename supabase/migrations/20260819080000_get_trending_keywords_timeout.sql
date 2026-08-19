-- =============================================================================
-- get_trending_keywords — lägg statement_timeout + search_path
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. En push skulle försöka köra om dem, inkl.
-- omklassificeringen av 18 131 artiklar. Se ORDER 091 §8.)
--
-- BAKGRUND (ORDER 096 §1, diagnos 2026-08-19):
--
--   Nätverkstab på gusto.science visar POST /rest/v1/rpc/get_trending_keywords
--   returnerar HTTP 500 med body:
--     {"code":"57014","message":"canceling statement due to statement timeout"}
--
--   Direkt curl (limit_n=8): 3.2 s → 500
--   Direkt curl (limit_n=30): 2.5 s → 200 (warm cache råkade landa under gränsen)
--
--   RPC:n definierades i 20260716120000_adopt_orphan_rpcs.sql UTAN
--   SET statement_timeout — ärver anon-rollens default (~3 s i Supabase)
--   som är för snäv för `unnest(keywords) over 466 905 rader + group by kw
--   HAVING count(*)>=3`.
--
--   Två parallella anrop per sidladdning (loadArticles → loadTrending +
--   loadCounts → loadTrending) förvärrar cold-cache-fallet. Gen-token-
--   fixen från ORDER 092 löste DOM-race, inte server-belastningen.
--
-- LÖSNING:
--
--   CREATE OR REPLACE med samma logik + samma boilerplate som
--   triad_coverage() / map_coverage() (ORDER 091/094):
--     SET search_path = public, pg_temp
--     SET statement_timeout = '30s'
--
--   Kroppen oförändrad — samma query, samma trend-kategorisering,
--   samma limit_n-param.
--
-- FÖRVÄNTAT EFTER MIGRATION:
--
--   select public.get_trending_keywords(8);
--     → 8 rader (sensory evaluation top, Psychology, food safety, …)
--   Ingen HTTP 500 från browsern.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_trending_keywords(limit_n integer default 20)
RETURNS TABLE(
  keyword text,
  total_count bigint,
  this_year bigint,
  last_year bigint,
  five_year_avg numeric,
  trend_direction text,
  trend_pct numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
SET statement_timeout = '30s'
AS $function$
  with kw_counts as (
    select
      kw as keyword,
      count(*) as total_count,
      count(*) filter (where year::int >= 2025) as this_year,
      count(*) filter (where year::int = 2024) as last_year,
      count(*) filter (where year::int between 2020 and 2024) as five_year_total
    from articles, unnest(keywords) as kw
    where keywords is not null
      and array_length(keywords, 1) > 0
      and year is not null
      and year ~ '^\d{4}$'
    group by kw
    having count(*) >= 3
  )
  select
    keyword,
    total_count,
    this_year,
    last_year,
    round(five_year_total::numeric / 5, 1) as five_year_avg,
    case
      when last_year = 0 and this_year > 0 then 'new'
      when last_year = 0 then 'stable'
      when this_year::numeric / last_year > 1.3 then 'rising'
      when this_year::numeric / last_year < 0.7 then 'declining'
      else 'stable'
    end as trend_direction,
    case
      when last_year = 0 then 0
      else round(((this_year::numeric - last_year) / last_year) * 100)
    end as trend_pct
  from kw_counts
  order by total_count desc
  limit limit_n
$function$;

GRANT EXECUTE ON FUNCTION public.get_trending_keywords(integer)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.get_trending_keywords(integer) IS
  'Trend-analys per keyword. ORDER 096: lade statement_timeout=30s + '
  'search_path för att stoppa 57014-timeouts under cold cache. '
  'Original-definition från 20260716120000_adopt_orphan_rpcs.sql.';
