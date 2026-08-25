-- =============================================================================
-- ORDER 153 — snapshot av articles.topic innan AI-baserad topic-classify
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- ⚠️  KÖR DENNA MIGRATION FÖRE `scripts/batch-topic-classify.ts --apply`.
--    Utan snapshot försvinner alla ~3,714 gamla 'uncategorized'-värden
--    vid UPDATE. Se rollback-block i slutet av denna fil.
--
-- BAKGRUND (2026-08-25):
--
--   Runda 4 (ORDER 147) + runda 5 (ORDER 152) flyttade 3,876 av 7,574
--   uncategorized-rader via keyword-tillägg. Kvar: ~3,714 rader vars
--   keywords är för generiska eller för specifika för att matcha
--   någon slug. Keyword-spåret är uttömt.
--
--   ORDER 153 AI-klassificerar residualen med Haiku 4.5 (Batches API).
--   3,714 rader ändras (potentiellt) i en single-column UPDATE på
--   articles.topic. Ingen rollback-väg i scriptet självt — denna
--   migration är den enda återvändo-möjligheten om AI-utfallet visar
--   sig fel efter apply.
--
--   Skillnad mot ORDER 147:s topic_reclassify_log:
--     * topic_reclassify_log lagrar PER FLYTT (article_id + old_topic +
--       new_topic + matched_kw + batch_id). Bra för keyword-baserade
--       rundor där bara MOVED rader loggas.
--     * topic_backup lagrar HELA POPULATIONEN som SKA rescoras (även
--       de som ev. rescoras till samma 'uncategorized'). Bra för AI-
--       rundor där vi inte vet i förväg vilka rader som flyttar.
--
--   Rollback: UPDATE articles.topic = backup.value WHERE article_id = ...
--
-- APPROACH:
--
--   Samma tabell-mönster som ORDER 149:s relevance_sci_educator_
--   researcher_backup: (article_id, value, snapshot_at, note). PRIMARY
--   KEY på article_id gör tabellen safe för re-run (samma rad blir
--   ON CONFLICT DO NOTHING via NOT EXISTS-check nedan).
--
--   Note-fältet fritt så framtida topic-backupar (från annan AI-runda
--   eller annan orsak) kan samexistera med olika note-värden.
--
-- FÖRVÄNTAT ANTAL: ~3,714 rader (mätt via articles 2026-08-25 efter
--   ORDER 152-apply). Sanity-checken efter INSERT skriver RAISE WARNING
--   om avvikelse.
--
-- GRANTS: service_role skriver + läser (batch-topic-classify + rollback-
--   flödet). authenticated SELECT för framtida admin-verktyg (samma
--   mönster som ORDER 149:s backup).
-- =============================================================================


begin;
set local statement_timeout = '10min';


create table if not exists public.topic_backup (
  article_id   uuid primary key,
  value        text,
  snapshot_at  timestamptz not null default now(),
  note         text
);

comment on table public.topic_backup is
  'ORDER 153: snapshot av articles.topic innan AI-baserad topic-classify. '
  'Rollback: UPDATE articles SET topic = backup.value FROM topic_backup '
  'WHERE articles.id = backup.article_id AND note = ''pre ORDER 153 v1 AI reclassify''.';


-- INSERT bara rader som INTE redan finns i backup (idempotens vid re-run).
-- Om samma migration körs igen efter apply skulle articles.topic vara ändrad
-- till AI-svaret och backup:en skulle överskriva den korrekta ursprungliga
-- 'uncategorized'-värdet med det NYA topic-värdet. NOT EXISTS-guarden
-- förhindrar det.

insert into public.topic_backup (article_id, value, note)
select id,
       topic,
       'pre ORDER 153 v1 AI reclassify'
from public.articles
where topic = 'uncategorized'
  and irrelevant is not true
  and not exists (
    select 1 from public.topic_backup b
     where b.article_id = articles.id
       and b.note = 'pre ORDER 153 v1 AI reclassify'
  );


-- Sanity: förvänta ~3,714 rader (±5% för pipeline-drift senaste dygnet).
do $$ declare n int; begin
  select count(*) into n from public.topic_backup
   where note = 'pre ORDER 153 v1 AI reclassify';
  raise notice 'ORDER 153 backup: % rader snapshotade (förväntat ~3714)', n;
  if n < 3500 or n > 4000 then
    raise warning 'ORDER 153: backup-antal % avviker från 3714 — undersök innan batch', n;
  end if;
end $$;


grant select, insert, update, delete on public.topic_backup to service_role;
grant select on public.topic_backup to authenticated;


commit;


-- =============================================================================
-- VERIFIERING EFTER APPLY (kör före batch-topic-classify):
--
--   -- 1. Antal rader i backup (målvärde ~3,714):
--   select count(*) from public.topic_backup
--    where note = 'pre ORDER 153 v1 AI reclassify';
--
--   -- 2. Jämför mot articles direkt — ska matcha exakt:
--   select
--     (select count(*) from public.articles
--       where topic = 'uncategorized' and irrelevant is not true) as articles_n,
--     (select count(*) from public.topic_backup
--       where note = 'pre ORDER 153 v1 AI reclassify')            as backup_n;
--   -- expected: identiska
--
--   -- 3. Alla värden är 'uncategorized' (fastställer att backup faktiskt
--   -- fångar den populationen som scriptet kommer att skriva över):
--   select value, count(*) from public.topic_backup
--    where note = 'pre ORDER 153 v1 AI reclassify'
--    group by value;
--   -- expected: 1 rad, ('uncategorized', ~3714)
-- =============================================================================


-- =============================================================================
-- ROLLBACK (om AI-utfallet visar sig fel efter batch-topic-classify):
--
--   begin;
--   set local statement_timeout = '15min';
--
--   update public.articles a
--      set topic = b.value
--     from public.topic_backup b
--    where a.id = b.article_id
--      and b.note = 'pre ORDER 153 v1 AI reclassify';
--
--   -- Bekräfta antalet återställda rader = ~3,714
--   select 'rollback: ' || count(*) || ' rader återställda till uncategorized'
--     from public.articles a
--     join public.topic_backup b
--       on a.id = b.article_id
--    where b.note = 'pre ORDER 153 v1 AI reclassify'
--      and a.topic = b.value;
--
--   commit;
--
--   -- Refresh map-MV:er efter rollback
--   select public.refresh_map_mvs();
--
--   -- Ev. städa backup-raderna (om rollback är permanent):
--   -- delete from public.topic_backup
--   --  where note = 'pre ORDER 153 v1 AI reclassify';
-- =============================================================================
