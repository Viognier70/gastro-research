-- =====================================================================
-- idx_backfill_institutions_queue
-- =====================================================================
-- Del 3 av 4. backfill-institutions:8. Query filtrerar också på
-- url IS NOT NULL AND episteme_sensory_pro IS NOT NULL, men den
-- selektiva biten är (source='openalex' AND institution_coords IS NULL).
-- De två extra filtren fångas som post-filter mot den trängre indexlistan.
-- =====================================================================

create index concurrently if not exists idx_backfill_institutions_queue
  on public.articles (id)
  where source = 'openalex'
    and institution_coords is null;
