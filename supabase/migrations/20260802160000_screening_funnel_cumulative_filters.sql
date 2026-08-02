-- =============================================================================
-- screening_funnel: kumulativa predikat — varje steg ⊆ föregående steg
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- INVARIANT (ny 2026-08-02, INFÖRD FÖR ATT INTE UPPREPAS):
--
--   Varje steg i tratten måste vara en delmängd av föregående steg.
--   Undantag: unika_doi är en distinct-count-metrik (inte radcount) och
--   räknar antalet unika DOI:er, inte antalet artiklar. Med den enda
--   naturliga betydelsen (distinct DOI ≤ rader med DOI ≤ alla rader)
--   är den ändå monoton mot indexerade och mot med_abstract i praktiken
--   eftersom uq_articles_url-constrainten (2026-08-02) hindrar
--   URL-dubbletter.
--
--   Alla andra steg är row counts och MÅSTE anges kumulativt: varje
--   filter innehåller ALLA föregående stegs predikat plus sitt eget.
--   Inga nya "bara det här villkoret"-filter längre.
--
-- BUGGHISTORIK (samma vy lagats tre gånger på en dag):
--
--   20260713130000 (skapelse):
--     - relevanta   = relevance_checked AND irrelevant = false
--     - med_imrad   = imrad_methods is not null           ← utan gate
--     - triad      = phronesis is not null                ← utan gate
--   → båda steget efter relevanta > relevanta.
--
--   20260802150000 (fix 1):
--     - triad     += irrelevant is not true               ← delfix, missade
--                                                          relevance_checked
--     - med_imrad =  oförändrat                          ← inte lagat
--   → triad fortfarande +829 över relevanta (relevance_checked=false-rader),
--     med_imrad +6538 över relevanta (både filter saknades).
--
--   20260802160000 (denna, uttömmande):
--     - alla row-count-steg får kumulativt predikat från indexerade
--       nedåt. Varje efterföljande steg lägger på exakt ett nytt
--       villkor. Bevisligen ⊆ föregående.
--
-- FÖR FRAMTIDA ÄNDRINGAR: om ett nytt trattsteg ska läggas till, kopiera
-- föregående stegs filter och lägg till EN och-klausul. Ändra aldrig ett
-- filter till att bli mindre restriktivt än föregående steg.
--
-- REFRESH: körs sist i denna migration + var 10:e min via befintlig
-- cron-job 'refresh-screening-funnel'.
-- =============================================================================

drop materialized view if exists public.screening_funnel;

create materialized view public.screening_funnel as
select
  -- STEG 1: indexerade — alla rader i articles.
  count(*) as indexerade,

  -- STEG 2: unika_doi — distinct-DOI-räkning (metrik, inte filter).
  -- Räknar antalet unika DOI-strängar bland doi.org-URL:er. Alltid
  -- ≤ indexerade (varje rad bidrar med max 1 distinct doi) och i
  -- praktiken ≤ med_abstract sedan uq_articles_url (2026-08-02).
  count(distinct nullif(regexp_replace(url, '.*doi\.org/', ''), ''))
    filter (where url ilike '%doi.org%') as unika_doi,

  -- STEG 3: med_abstract — DOI-havande + abstract ≥ 100 tecken.
  -- Kumulativt: bara DOI-havande rader räknas (så delmängd av unika_doi
  -- i praktiken; garantin är strikt mot indexerade).
  count(*) filter (
    where url ilike '%doi.org%'
      and abstract is not null
      and length(trim(abstract)) >= 100
  ) as med_abstract,

  -- STEG 4: screenade — ovan + relevance_checked = true.
  count(*) filter (
    where url ilike '%doi.org%'
      and abstract is not null
      and length(trim(abstract)) >= 100
      and relevance_checked = true
  ) as screenade,

  -- STEG 5: relevanta — ovan + irrelevant = false.
  count(*) filter (
    where url ilike '%doi.org%'
      and abstract is not null
      and length(trim(abstract)) >= 100
      and relevance_checked = true
      and irrelevant = false
  ) as relevanta,

  -- STEG 6: med_imrad — ovan + imrad_methods is not null.
  -- Exponerad för framtida bruk; ingår inte i frontendens FUNNEL_STEPS
  -- idag men måste vara monoton eftersom SQL-vyn läses direkt.
  count(*) filter (
    where url ilike '%doi.org%'
      and abstract is not null
      and length(trim(abstract)) >= 100
      and relevance_checked = true
      and irrelevant = false
      and imrad_methods is not null
  ) as med_imrad,

  -- STEG 7: triad_analyserade — ovan + phronesis ≠ null.
  -- Educator-researcher-fältet är canary (skrivs sist av pipelinen);
  -- samma mönster som weekly-newsletter använder för strikt TRIAD-detekt.
  count(*) filter (
    where url ilike '%doi.org%'
      and abstract is not null
      and length(trim(abstract)) >= 100
      and relevance_checked = true
      and irrelevant = false
      and phronesis_educator_researcher is not null
  ) as triad_analyserade
from public.articles;

revoke all on public.screening_funnel from anon, authenticated;
grant select on public.screening_funnel to anon, authenticated;

-- Immediate refresh så tratten läser rätt tal före nästa cron-tick.
refresh materialized view public.screening_funnel;


-- =============================================================================
-- Verifiering (efter apply):
--
--   -- 1. Monotonitetstest (KRITISK invariant):
--   select
--     indexerade,
--     unika_doi,
--     med_abstract,
--     screenade,
--     relevanta,
--     med_imrad,
--     triad_analyserade,
--     -- alla ska vara true:
--     med_abstract      <= indexerade        as m3_le_m1,
--     screenade         <= med_abstract      as m4_le_m3,
--     relevanta         <= screenade         as m5_le_m4,
--     med_imrad         <= relevanta         as m6_le_m5,
--     triad_analyserade <= relevanta         as m7_le_m5
--     -- unika_doi är distinct-count, kollas separat:
--     , unika_doi       <= indexerade        as udoi_le_m1
--   from public.screening_funnel;
--   -- expected: alla m*_le_*-kolumner = true
--
--   -- 2. Cron-jobb oförändrat:
--   select jobname, schedule, active from cron.job where jobname = 'refresh-screening-funnel';
--   -- expected: 1 rad, active = true
-- =============================================================================
