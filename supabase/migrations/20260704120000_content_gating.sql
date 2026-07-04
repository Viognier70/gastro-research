-- =====================================================================
-- K4.1 — Content gating for public.articles
-- =====================================================================
-- Purpose: stop the anon key from returning premium TRIAD/IMRAD content
-- via /rest/v1/articles?select=*. All public reads must go through the
-- articles_public view (metadata + presence booleans only); full rows
-- are served through the SECURITY DEFINER RPC get_articles_full, which
-- returns rows only if the caller has profiles.is_pro = true.
--
-- APPLY THIS IN TWO STAGES:
--
--   STAGE A (safe pre-deploy — sections 0, 1, 2): creates the view and
--     grants. Zero impact on main because articles table is untouched.
--     Run this BEFORE deploying fix/phase3-gating so the preview can
--     load articles_public.
--
--   STAGE B (post-verify — section 3): REVOKE + enable RLS on
--     public.articles. This is the actual paywall. Run ONLY after the
--     preview URL has been verified end-to-end (anon flow, Pro flow,
--     maps/graphs/counts, semantic search) and fix/phase3-gating is
--     merged to main and deployed.
--
--   Section 4 lists verification queries you can run at any point.
--
-- Premium columns (never exposed to anon):
--   episteme_*, techne_*, phronesis_*, bridge_episteme_techne_*,
--   bridge_techne_phronesis_*, imrad_introduction, imrad_methods,
--   imrad_results, imrad_discussion, core_claim
--
-- Public metadata (exposed via articles_public):
--   id, title, headline_en, headline_sv, insight, authors, journal,
--   year, topic, url, citation_count, fetched_at, source, source_label,
--   study_type, knowledge_type, country, countries, claim_keywords,
--   limitation, primary_institution, institution_coords,
--   institution_rank, relevance_* (all role weightings), irrelevant,
--   plus presence booleans has_episteme_<role>, has_core_claim,
--   has_imrad (to preserve current filter/order UX).
--
-- Confirmed with Anders 2026-07-04:
--   A) insight — PUBLIC. Exposed in the view.
--   B) bridge_* — PREMIUM. Excluded from the view.
--   C) headline_en — PUBLIC. Exposed in the view (anon feed keeps the
--      gold "Gusto Science" headline).
-- =====================================================================

-- =====================================================================
-- STAGE A — safe to run pre-deploy (sections 0, 1, 2)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Verify get_articles_full RPC already exists (manually created in
--    prod). Refuses to run this migration if it doesn't.
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'get_articles_full'
  ) then
    raise exception 'get_articles_full RPC not found in public schema — create it before running this migration';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Public view: metadata + presence booleans, no premium payload.
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
  -- Relevance weights (per role, not premium content):
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
  -- Presence booleans replace the current `episteme_XX=not.is.null`
  -- filter idiom used in feed queries and count queries:
  (a.episteme_sommelier          is not null) as has_episteme_sommelier,
  (a.episteme_chef               is not null) as has_episteme_chef,
  (a.episteme_gastronomy         is not null) as has_episteme_gastronomy,
  (a.episteme_fb_manager         is not null) as has_episteme_fb_manager,
  (a.episteme_food_researcher    is not null) as has_episteme_food_researcher,
  (a.episteme_sensory_pro        is not null) as has_episteme_sensory_pro,
  (a.core_claim                  is not null) as has_core_claim,
  (a.imrad_introduction          is not null) as has_imrad;

alter view public.articles_public owner to postgres;

-- ---------------------------------------------------------------------
-- 2. Grants: view is readable by anon + authenticated. RPC (already in
--    prod) must be executable by authenticated only; anon should never
--    call it. Re-assert the grants defensively.
-- ---------------------------------------------------------------------
grant select on public.articles_public to anon, authenticated;

revoke all on function public.get_articles_full(uuid[]) from public;
grant execute on function public.get_articles_full(uuid[]) to authenticated;

-- =====================================================================
-- STAGE B — apply ONLY after fix/phase3-gating is verified on preview
--          and merged into main (section 3 below)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 3. Close the REST leak on public.articles. Two belt-and-braces steps:
--      a) REVOKE select from anon + authenticated so PostgREST cannot
--         serve /rest/v1/articles to them at all.
--      b) Enable RLS with no permissive policy for anon/authenticated,
--         so even if a grant is later restored by accident the table
--         still denies reads.
--    service_role bypasses RLS AND ignores grants, so daily-fetch,
--    pipeline, backfill-*, synthesize, etc. keep working. Same for the
--    SECURITY DEFINER RPC, which reads as its owner.
--
-- BEFORE RUNNING these two blocks: confirm the frontend on
-- fix/phase3-gating is already deployed and points at articles_public.
-- ---------------------------------------------------------------------
revoke select on public.articles from anon;
revoke select on public.articles from authenticated;

alter table public.articles enable row level security;
-- Intentionally no policy for anon/authenticated. service_role bypasses
-- RLS. If a future feature needs direct authenticated read, add a
-- narrow policy scoped to that use case; do not open the whole table.

-- ---------------------------------------------------------------------
-- 4. Impact checklist — run these in the Supabase SQL editor after
--    apply to confirm nothing else silently broke:
--      select has_table_privilege('anon',           'public.articles', 'SELECT');           -- expect false
--      select has_table_privilege('authenticated',  'public.articles', 'SELECT');           -- expect false
--      select has_table_privilege('anon',           'public.articles_public', 'SELECT');    -- expect true
--      select has_table_privilege('authenticated',  'public.articles_public', 'SELECT');    -- expect true
--      select has_function_privilege('anon',          'public.get_articles_full(uuid[])', 'EXECUTE'); -- expect false
--      select has_function_privilege('authenticated', 'public.get_articles_full(uuid[])', 'EXECUTE'); -- expect true
-- =====================================================================
