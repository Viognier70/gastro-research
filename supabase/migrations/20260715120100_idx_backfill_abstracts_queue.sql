-- =====================================================================
-- idx_backfill_abstracts_queue
-- =====================================================================
-- Del 2 av 4. backfill-abstracts:121 (1min-cron, avaktiverat 2026-07-14
-- men kod kvar). Kön är tömd idag; index håller framtida re-aktivering
-- från att seq-scanna 456k rader.
-- =====================================================================

create index concurrently if not exists idx_backfill_abstracts_queue
  on public.articles (id)
  where abstract is null
    and abstract_attempted_at is null;
