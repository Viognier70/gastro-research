-- =============================================================================
-- ORDER 180 A v2 (2026-08-28) — get_trending_keywords: case-heuristik ersätter
-- numerisk OpenAlex-noise-filter
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN.
--
-- BAKGRUND (2026-08-28 diagnos):
--
--   Föregående version (20260827140000) filtrerade på numerisk tröskel:
--     (a) recent-2y * 100 >= total
--     (b) five_year_total * 20 >= total  (≡ 5yr_avg * 100 >= total)
--
--   Applicerades i prod, tog bort Biochemistry (5yr_avg 1.2 → filter b
--   FAIL). Men Psychology, Computer science, Culinary Culture and Tourism,
--   Sociology, Art, Geography, Internal medicine och andra OpenAlex-taxonomi-
--   taggar passerade alla — deras 5yr_avg är för hög (5-150) för att
--   fångas av "historisk tail dominerar recent"-mönstret.
--
--   Verifierat 2026-08-28 via anon-RPC-anrop:
--     Psychology: total 2833, 5yr_total 749 → 749*20=14980 >> 2833 PASS
--     CS:         total 2006, 5yr_total 120 → 120*20=2400  >  2006 PASS
--     CCT:        total 1527, 5yr_total 99  → 99*20=1980   >  1527 PASS
--
--   Ingen numerisk tröskel kan filtrera dessa utan att också ta bort
--   legitima forskningskeywords med jämförbar 5yr-volym.
--
-- REAL SIGNAL — CASE-DISCIPLIN:
--
--   OpenAlex normaliserar sina ämnesetiketter till Title Case
--   ("Psychology", "Computer science", "Culinary Culture and Tourism",
--   "Environmental health"). Användar/topic-genererade forskningskeywords
--   är alltid gemena ("sensory evaluation", "fermentation",
--   "lactic acid bacteria", "volatile compounds").
--
--   Diagnostik-utputen från 2026-08-28 topp-30:
--     Versaliserade (första bokstav stor) — 14/30, alla OpenAlex-taggar
--     Gemena — 16/30, alla legitima forskningskeywords
--
--   Case-heuristik `substring(kw from 1 for 1) = lower(substring(kw from
--   1 for 1))` fångar alla 14 versaliserade utan att missa någon av de
--   16 gemena. Signal-till-brus ≈ 100%.
--
-- ENDA KOSTNAD: Saccharomyces cerevisiae (latinskt jäst-artnamn, versalt)
--   försvinner ur Pulse. Kompenseras av att fermentation- och lactic acid
--   bacteria-artiklar dyker upp under andra keywords. Om det visar sig
--   kritiskt läggs whitelist till som en enkel OR-klausul.
--
-- SIGNATUR: identisk med 20260819080000 / 20260827140000 → CREATE OR
--   REPLACE ersätter rent, grants preserverade.
--
-- ROT-ORSAK EJ FIXAD (samma nota som v1): RPC:n opererar på hela ~466k-
--   articles-korpus, inte TRIAD-delmängd. Case-filter tar bort det mest
--   uppenbara symptomet; population-scoping mot TRIAD-set är kvar
--   som separat ORDER.
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
       -- ORDER 180 A v2: case-heuristik ersätter numeriska filter från v1.
       -- OpenAlex normaliserar taxonomi-taggar till Title Case (Psychology,
       -- Computer science). Riktiga forskningskeywords är gemena (sensory
       -- evaluation, fermentation). Första-bokstav-gemen = keyword; versal
       -- = taxonomi-tag. Enda undantag: latinska artnamn (Saccharomyces),
       -- acceptabel förlust.
       and substring(kw from 1 for 1) = lower(substring(kw from 1 for 1))
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
--   -- 1. Sju versaliserade OpenAlex-taggar ska vara borta:
--   select keyword from public.get_trending_keywords(50)
--    where keyword in ('Psychology','Computer science','Sociology','Art',
--                      'Geography','Culinary Culture and Tourism',
--                      'Internal medicine','Mathematics','Advertising',
--                      'Environmental health','Social psychology','Taste',
--                      'Obesity, Physical Activity, Diet');
--   -- expected: 0 rader
--
--   -- 2. Gemena forskningskeywords finns kvar (spot-check):
--   select keyword, total_count, this_year, last_year, five_year_avg,
--          trend_direction, trend_pct
--     from public.get_trending_keywords(15);
--   -- expected: sensory evaluation, food safety, fermentation, lactic acid
--   -- bacteria, volatile compounds osv — alla gemena.
--
--   -- 3. Antal keywords post-filter (för sanity):
--   select count(*) from public.get_trending_keywords(10000);
--   -- expected: färre än v1 gav (v1 gav 1000-cap-hit; case-filter tar
--   -- bort ytterligare N versaliserade taxonomi-taggar).
--
--   -- 4. Är Saccharomyces cerevisiae verkligen borta? (som förväntat):
--   select keyword from public.get_trending_keywords(1000)
--    where keyword ilike 'saccharomyces%';
--   -- expected: 0 rader. Om kritiskt saknat, lägg till whitelist-klausul:
--   --   and (substring(kw from 1 for 1) = lower(substring(kw from 1 for 1))
--   --        or kw in ('Saccharomyces cerevisiae', ...))
-- =============================================================================
