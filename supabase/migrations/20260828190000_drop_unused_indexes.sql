-- =============================================================================
-- ORDER 182 (2026-08-28) — droppa fyra oanvända index på articles
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN.
--
-- BAKGRUND:
--
--   pg_stat_user_indexes-diagnos 2026-08-28 visade fem index på
--   public.articles med noll scans över 119 dagar (stats_reset
--   2026-04-30). Kod-audit + EXPLAIN ANALYZE bekräftar att fyra är
--   säkra att droppa; den femte (idx_articles_relevance_checked_at)
--   är faktiskt användbar men gusto_health-subqueryn missade partial-
--   predikatet — fix i separat migration 20260828200000.
--
-- DROPPADE HÄR (~58 MB reclaim):
--
--   idx_articles_authors               36 MB
--     Enda kod-referens är stickprov-author-parity.ts med filtret
--     `authors=not.is.null` (låg selektivitet, ingen index-vinst) plus
--     write-vägar i daily-fetch/backfill-authors-openalex. Inget
--     produktions-anrop drar nytta.
--
--   idx_articles_triad_confidence      22 MB
--     Kolumnen triad_confidence har NOLL referenser i functions,
--     scripts, migrations eller frontend. Legacy-fält från äldre
--     TRIAD-scoring-iteration. Även kolumnen kan sannolikt droppas
--     men det är separat migration.
--
--   idx_backfill_affiliations_queue    112 kB
--     Matchar backfill-affiliations queue-query men kön är i praktiken
--     tom (project_empty_backfill_crons memory-not: ~2880 tomma jobb/
--     dygn). Planner picker seq-scan.
--
--   idx_backfill_abstracts_queue       160 kB
--     Matchar backfill-abstracts-query. Samma seq-scan-mönster som
--     affiliations-queue — kön är tom, planner picker seq över LIMIT 200
--     som slutar tidigt.
--
-- INTE DROPPAT:
--
--   idx_articles_relevance_checked_at  6,4 MB
--     EXPLAIN ANALYZE 2026-08-28: med `relevance_checked = true` i
--     WHERE går queryn från 1179 ms (seq-scan) till 9,5 ms (index-scan).
--     Indexet är korrekt — partial-predikatet `where relevance_checked
--     = true` matchade inte gusto_health-subqueryn utan den klausulen.
--     Fix i 20260828200000_gusto_health_relevance_takt_use_index.sql.
--
-- ÅTERSTÄLLNING: kan återskapas via CREATE INDEX CONCURRENTLY med samma
-- predikat om framtida query-mönster ändrar planner-val.
--
-- CONCURRENTLY: så backfill-motorer och läs-anrop inte låses under drop.
-- Kan inte köras i transaktion.
-- =============================================================================


drop index concurrently if exists public.idx_articles_authors;
drop index concurrently if exists public.idx_articles_triad_confidence;
drop index concurrently if exists public.idx_backfill_affiliations_queue;
drop index concurrently if exists public.idx_backfill_abstracts_queue;


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   select indexname, pg_size_pretty(pg_relation_size(indexname::regclass))
--     from pg_indexes
--    where schemaname = 'public'
--      and tablename = 'articles'
--      and indexname in (
--        'idx_articles_authors',
--        'idx_articles_triad_confidence',
--        'idx_backfill_affiliations_queue',
--        'idx_backfill_abstracts_queue'
--      );
--   -- expected: 0 rader.
--
--   -- Bekräfta storleks-reclaim:
--   select pg_size_pretty(pg_total_relation_size('public.articles')) as articles_total;
--   -- expected: ~58 MB mindre än före drop.
-- =============================================================================
