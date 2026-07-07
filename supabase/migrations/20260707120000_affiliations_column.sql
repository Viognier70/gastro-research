-- =====================================================================
-- Affiliation columns + articles_public view refresh
-- =====================================================================
-- Purpose: stop daily-fetch from throwing away source-provided
-- institution/affiliation data. Adds two columns that the fetch mapper
-- already computes for OpenAlex, and exposes them (plus `institutions`)
-- via articles_public so the frontend can query per-institution.
--
-- Context (diagnosis 2026-07-07):
--   Scopus + OpenAlex + PubMed all return per-author affiliation data.
--   daily-fetch's OpenAlex mapper builds `institutions` and
--   `institution_coords` correctly but the saveArticle insert never
--   persists them. Scopus + PubMed don't even extract affiliation names,
--   only country. Result: 267 066 relevant articles, 630 with
--   primary_institution. The user's own ~13 publications sit unlinked
--   in the corpus because the pipeline discarded the affiliation text.
--
--   Fix has two halves:
--     A) Persist at ingestion — this migration + daily-fetch changes.
--     B) Backfill history — future edge fn re-fetches affiliations for
--        the existing corpus (~2-3 days wall clock).
--
-- Deploy order:
--   1. Apply this migration to prod FIRST (safe — additive columns +
--      view refresh, zero impact on existing reads).
--   2. Deploy the updated daily-fetch fn.
--
--   Running daily-fetch first would fail on the new insert fields.
--
-- Column choices:
--   affiliations text[]  — RAW affiliation strings from each source,
--                          preserves department/campus detail (e.g.
--                          "Örebro University, School of Hospitality,
--                          Grythyttan"). Free-text; use ILIKE or
--                          fulltext for search.
--   institutions text[]  — Normalised institution display names (e.g.
--                          "Örebro University"). Already written by
--                          backfill-institutions in prod, so column
--                          exists in some form; IF NOT EXISTS keeps
--                          this idempotent.
-- =====================================================================

alter table public.articles
  add column if not exists affiliations text[],
  add column if not exists institutions text[];

-- ---------------------------------------------------------------------
-- Refresh articles_public view — add affiliations + institutions at the
-- end so existing consumers keep working (create or replace requires
-- column-set to be a superset with matching order for the original set).
-- ---------------------------------------------------------------------
create or replace view public.articles_public as
select
  a.id,
  a.title,
  a.headline_en,
  a.headline_sv,
  a.insight,
  a.authors,
  a.journal,
  a.year,
  a.topic,
  a.url,
  a.citation_count,
  a.fetched_at,
  a.source,
  a.source_label,
  a.study_type,
  a.knowledge_type,
  a.country,
  a.countries,
  a.claim_keywords,
  a.limitation,
  a.primary_institution,
  a.institution_coords,
  a.institution_rank,
  a.irrelevant,
  a.relevance_sommelier,
  a.relevance_chef,
  a.relevance_creator,
  a.relevance_waiter,
  a.relevance_educator,
  a.relevance_researcher,
  a.relevance_fbmanager,
  a.relevance_hotelier,
  a.relevance_sci_sommelier,
  a.relevance_sci_chef,
  a.relevance_sci_gastronomy,
  a.relevance_sci_fb_manager,
  a.relevance_sci_food_researcher,
  a.relevance_sci_creator,
  a.relevance_sci_fbmanager,
  a.relevance_sci_researcher,
  a.relevance_sci_waiter,
  a.relevance_sci_educator,
  a.relevance_sci_sensory_pro,
  a.relevance_sci_culinary_pro,
  a.relevance_sci_gastronomy_culture,
  a.relevance_sci_hospitality_mgmt,
  a.relevance_sci_educator_researcher,
  (a.episteme_sommelier          is not null) as has_episteme_sommelier,
  (a.episteme_chef               is not null) as has_episteme_chef,
  (a.episteme_gastronomy         is not null) as has_episteme_gastronomy,
  (a.episteme_fb_manager         is not null) as has_episteme_fb_manager,
  (a.episteme_food_researcher    is not null) as has_episteme_food_researcher,
  (a.episteme_sensory_pro        is not null) as has_episteme_sensory_pro,
  (a.core_claim                  is not null) as has_core_claim,
  (a.imrad_introduction          is not null) as has_imrad,
  -- NEW: affiliation-level linkage for the institution-vy filter.
  -- Both are text[] so PostgREST `cs.{"..."}` containment works.
  a.institutions,
  a.affiliations;

alter view public.articles_public owner to postgres;
grant select on public.articles_public to anon, authenticated;

-- =====================================================================
-- Verification (run in SQL editor after apply):
--
--   -- Columns exist?
--   select column_name from information_schema.columns
--    where table_schema='public' and table_name='articles'
--      and column_name in ('affiliations','institutions');
--   -- expected: 2 rows
--
--   -- View exposes both?
--   select column_name from information_schema.columns
--    where table_schema='public' and table_name='articles_public'
--      and column_name in ('affiliations','institutions');
--   -- expected: 2 rows
--
--   -- Anon can select both?
--   select has_column_privilege('anon',
--     'public.articles_public','affiliations','SELECT') as ok_affil,
--          has_column_privilege('anon',
--     'public.articles_public','institutions','SELECT') as ok_insts;
--   -- expected: t, t
-- =====================================================================
