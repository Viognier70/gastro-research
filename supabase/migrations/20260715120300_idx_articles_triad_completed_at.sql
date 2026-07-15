-- =====================================================================
-- idx_articles_triad_completed_at
-- =====================================================================
-- Del 4 av 4. health-alert:316 räknar rader där triad_completed_at
-- < now() - 24h (range-scan på tidsstämpel). gusto_health:s
-- triad_takt_24h använder samma kolumn. Framtida triad-stall-alarm
-- kommer också behöva den.
--
-- Skillnad mot de andra tre: kolumn-index på (triad_completed_at)
-- istället för (id), för range-scan. Partial NOT NULL så indexet
-- bara innehåller rader där TRIAD faktiskt körts.
-- =====================================================================

create index concurrently if not exists idx_articles_triad_completed_at
  on public.articles (triad_completed_at)
  where triad_completed_at is not null;
