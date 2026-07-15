-- =====================================================================
-- idx_backfill_affiliations_queue — VIKTIGAST av de fyra kvarvarande
-- =====================================================================
-- Del 1 av 4 (splittad efter fail 2026-07-15 08:33: Supabase CLI batchar
-- multipla `CREATE INDEX CONCURRENTLY` i en pipeline vilket PG förbjuder
-- med SQLSTATE 25001 "cannot be executed within a pipeline". Splittning
-- till en fil per index kringgår detta — varje `db push` kör en fil,
-- en pipeline, ett CREATE INDEX CONCURRENTLY.
--
-- backfill-affiliations:144 (1min-cron, avaktiverat 2026-07-14 men kod
-- och schemaställe kvar) och health-alert:302 (30min-cron) delar nästan
-- samma filter. Väktaren själv seq-scannade tabellen 48 gånger/dygn.
--
-- OBS: health-alert:302 saknar för närvarande `irrelevant = false` i
-- sitt filter (rad 302-306 grepad 2026-07-14: institutions IS NULL
-- AND affiliation_attempted_at IS NULL AND url ILIKE '%doi.org%').
-- Med partial-predikatet nedan innehållande `irrelevant = false` kan
-- planneraren inte bevisa att health-alert:302:s resultatmängd ryms
-- i indexet — det blir inte användbart för den queryn förrän
-- health-alert:302 uppdateras. Backfill-affiliations:144 matchar
-- exakt och drar full nytta. Anders 2026-07-15: inkludera
-- `irrelevant = false` i indexet, uppdatera health-alert:302 separat.
-- =====================================================================

create index concurrently if not exists idx_backfill_affiliations_queue
  on public.articles (id)
  where institutions is null
    and affiliation_attempted_at is null
    and irrelevant = false;
