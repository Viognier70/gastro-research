-- =============================================================================
-- ORDER 180 A (2026-08-27) — get_trending_keywords: filtrera OpenAlex-taggar
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN.
--
-- BAKGRUND:
--
--   Research Pulse-panelen visar "N articles total · 2025:X · 2024:Y · 5yr
--   avg:Z" per keyword. Fyra fallande pilar (-33% till -67%) i toppen läses
--   som fältrörelse men är brus på små tal (1 vs 3). Två keywords sticker
--   ut som misskatalog:
--
--     Biochemistry:     total 1600, 2025: 1, 2024: 3,  5yr avg 1.2
--     Computer science: total 2003, 2025: 27, ...       5yr avg ~5-10
--
--   Båda är breda OpenAlex-ämnesetiketter — inte forskningskeywords från
--   TRIAD-analyserade artiklar. De hamnade i listan för att pre-korpus-
--   artiklar bär dem via OpenAlex-metadata utan att någonsin ha TRIAD-
--   analyserats.
--
-- KRITERIUM (ORDER 180 Anders):
--
--   "Ta bort rader där summan av årstalen är två storleksordningar under
--    'articles total'. Det fångar Biochemistry, Computer science och de
--    andra som mäter fel population."
--
--   Två storleksordningar = 100×. Två tests kombineras med AND — båda
--   måste passa för att keywordet ska behållas:
--     (a) senaste två år (this_year + last_year) * 100 >= total
--     (b) five_year_avg * 100 >= total
--
--   Test (a) fångar keywords med försumbar recent-2-års-aktivitet
--   (Bio: 4 × 100 = 400 < 1600 → filter). Test (b) fångar keywords vars
--   längre-tid-pace är för låg mot totalen (CS: 5-10 × 100 = 500-1000
--   < 2003 → filter). AND-logik gör kriteriet konservativt: enstaka
--   sparsam-årsdipp under (a) räddas om (b) håller — kortsiktig brus
--   filtreras inte som permanent noise.
--
-- ANMÄRKNING — ROT-ORSAK EJ FIXAD:
--
--   RPC:n opererar på hela articles-tabellen (~466k rader med keywords),
--   inte TRIAD-delmängden (~39k). Meta-raden i UI:t säger "TRIAD-
--   analysed articles" men RPC:n räknar över broader-population. Detta
--   filter tar bort de värsta symptomen; rot-orsak (population-scoping
--   av RPC:n mot TRIAD-set) tas som egen ORDER — kräver att flera
--   callers (Feed pulse, Overview pulse, weekly digest sectionB)
--   granskas för down-stream-effekt på keyword-rank.
--
-- SIGNATUR: identisk med 20260819080000 → CREATE OR REPLACE ersätter rent.
--   Grants preserverade.
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
       -- ORDER 180 A: OpenAlex-ämnesetikett-filter. Behåll keyword ENDAST
       -- om båda:
       --   (a) recent 2y (this + last) * 100 >= total
       --   (b) five_year_avg * 100 >= total  (= five_year_total * 20 >= total)
       -- Bio: (a) 4×100=400<1600 fail; (b) 6×20=120<1600 fail → filter
       -- CS:  (a) 27×100=2700>=2003 pass; (b) ~10×20=~200<2003 fail → filter
       and count(*) filter (where year::int >= 2024) * 100 >= count(*)
       and count(*) filter (where year::int between 2020 and 2024) * 20 >= count(*)
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


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Biochemistry + Computer science BORTA från topp-20:
--   select keyword, total_count, this_year, last_year, five_year_avg
--     from public.get_trending_keywords(20)
--    where keyword ilike 'biochem%' or keyword ilike 'computer%';
--   -- expected: 0 rader
--
--   -- 2. Topp-8 för granskning (subjektiv — ska vara TRIAD-relevanta keywords):
--   select keyword, total_count, this_year, last_year, five_year_avg,
--          trend_direction, trend_pct
--     from public.get_trending_keywords(8);
--
--   -- 3. Diagnostik — vilka keywords ryker och varför:
--   with pre_filter as (
--     select kw, count(*) as total,
--            count(*) filter (where year::int >= 2024) as recent_2y,
--            round((count(*) filter (where year::int between 2020 and 2024))::numeric / 5, 1) as five_yr_avg
--       from articles, unnest(keywords) as kw
--      where keywords is not null and array_length(keywords, 1) > 0
--        and year ~ '^\d{4}$'
--      group by kw having count(*) >= 3
--   )
--   select kw, total, recent_2y, five_yr_avg,
--          case
--            when recent_2y * 100 < total then 'fails (a) — recent 2y för lågt'
--            when five_yr_avg * 100 < total then 'fails (b) — 5yr avg för lågt'
--            else 'kept'
--          end as status
--     from pre_filter
--    where total >= 500
--    order by total desc limit 40;
-- =============================================================================
