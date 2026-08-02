-- =============================================================================
-- screening_funnel: gate triad_analyserade på irrelevant is not true
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- BUGG (2026-08-02):
--
--   Tratten visade 32 989 "Relevant" följt av 38 271 "TRIAD analysed" —
--   steget EFTER är större än steget FÖRE. Icke-monoton tratt betyder att
--   filterlogiken skiljer sig mellan stegen, inte att verkligheten är
--   omöjlig.
--
--   Föregående definition (20260713130000):
--     relevanta         = relevance_checked = true AND irrelevant = false
--     triad_analyserade = phronesis_educator_researcher is not null
--
--   Artiklar som TRIAD-analyserats INNAN de senare markerades irrelevant
--   räknas i triad_analyserade men inte i relevanta. Skillnad ~5 300 rader
--   idag (38 271 - 32 989). Efter fix: ~32 940 (< 32 989 → monotont).
--
-- FIX: lägg irrelevant-gaten även på triad_analyserade. Använder samma
--      "irrelevant is not true" som frontendens gate (inte "= false")
--      för att också inkludera irrelevant IS NULL — historiska TRIAD-
--      artiklar från innan relevance_checked-flaggan fanns.
--
-- CONCURRENTLY inte relevant här: materialized view refreshas via cron var
-- 10:e min (jobbet 'refresh-screening-funnel'); vyn är 1 rad så refresh är
-- mikroskopisk. Ingen unique-index behövs.
-- =============================================================================

drop materialized view if exists public.screening_funnel;

create materialized view public.screening_funnel as
select
  count(*) as indexerade,
  count(distinct nullif(regexp_replace(url, '.*doi\.org/', ''), ''))
    filter (where url ilike '%doi.org%') as unika_doi,
  count(*) filter (where abstract is not null
                     and length(trim(abstract)) >= 100) as med_abstract,
  count(*) filter (where relevance_checked = true) as screenade,
  count(*) filter (where relevance_checked = true and irrelevant = false) as relevanta,
  count(*) filter (where imrad_methods is not null) as med_imrad,
  count(*) filter (where phronesis_educator_researcher is not null
                     and irrelevant is not true) as triad_analyserade
from public.articles;

revoke all on public.screening_funnel from anon, authenticated;
grant select on public.screening_funnel to anon, authenticated;

-- Refresh direkt så tratten läser rätt tal före nästa cron-tick.
refresh materialized view public.screening_funnel;


-- =============================================================================
-- Verifiering (efter apply):
--
--   select relevanta, triad_analyserade, triad_analyserade <= relevanta as monoton
--     from public.screening_funnel;
--   -- expected: monoton = true; triad_analyserade ≈ 32 940 (baseline 2026-08-02)
--
--   -- Cron-jobbet är oförändrat men lista för säkerhets skull:
--   select jobname, schedule, active from cron.job where jobname = 'refresh-screening-funnel';
--   -- expected: 1 rad, active = true
-- =============================================================================
