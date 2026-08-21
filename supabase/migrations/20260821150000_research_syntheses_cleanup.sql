-- =============================================================================
-- research_syntheses: droppa keywords, topics, professions
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- BAKGRUND (ORDER 122, 2026-08-21):
--
--   Halvbyggda kolumner efter field-audit 2026-08-21:
--     keywords    text[]  — fylld på 2/25 rader (backfill-artifact,
--                           inte skriven av synthesize-edge-fn)
--     topics      text[]  — redundant array-version av singular topic
--     professions text[]  — redundant array-version av singular role
--
--   Divergence + evidence_type utökas istället (i samma order-batch)
--   till att fyllas av synthesize-fn via utökad Haiku-prompt.
--
-- KONSUMENT-AUDIT (2026-08-21):
--   - synthesize/index.ts: skriver topics + professions i upsert-
--     objektet (rad 76-77 pre-fix). Rensas i samma commit — ny
--     upsert utan dessa fält.
--   - synthesize-batch/index.ts: 0 grep-träffar för keywords/topics/
--     professions. Inte påverkad.
--   - Frontend loadSyntheses (index.html rad ~6605): SELECT-fields
--     är `id, title, synthesis, topic, role, article_count, updated_at`.
--     Inte påverkad.
--   - Andra konsumenter: inga hittade i grep.
--
--   Slutsats: säkert att droppa. Frontend och batch-jobbet fortsätter
--   fungera; edge-fn:en får sin upsert uppdaterad i samma commit.
-- =============================================================================

ALTER TABLE public.research_syntheses
  DROP COLUMN IF EXISTS keywords,
  DROP COLUMN IF EXISTS topics,
  DROP COLUMN IF EXISTS professions;


-- =============================================================================
-- SCHEMA-CACHE RELOAD
-- =============================================================================
NOTIFY pgrst, 'reload schema';


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Kolumnerna borta
--   SELECT column_name FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='research_syntheses'
--    ORDER BY ordinal_position;
--   -- expected: 14 rader (17 - 3), utan keywords/topics/professions
--
--   -- 2. Sanity — alla 25 rader finns kvar, ingen tappad
--   SELECT count(*) FROM public.research_syntheses;
--   -- expected: 25
--
--   -- 3. synthesize-fn (efter deploy) skriver rätt fält vid nästa
--   --    invoke. Testa manuellt via curl:
--   -- curl -H "apikey:$SB_ANON" -H "Authorization:Bearer $SB_ANON" \
--   --      -H "Content-Type: application/json" \
--   --      "$SB_URL/functions/v1/synthesize" \
--   --      -d '{"role":"sensory_pro","topic":"flavor_science"}'
--   -- Kolla att divergence + evidence_type kommer med i svars-JSON:et.
-- =============================================================================
