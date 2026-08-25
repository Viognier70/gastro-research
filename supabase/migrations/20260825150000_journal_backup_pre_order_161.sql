-- =============================================================================
-- ORDER 161 — snapshot av articles.journal innan OpenAlex-backfill
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- ⚠️  KÖR DENNA MIGRATION FÖRE `scripts/backfill-empty-journals.ts --apply`.
--    Populationen är 356 rader (mätt 2026-08-25); alla har journal NULL eller
--    tom sträng och irrelevant IS NOT TRUE. Rollback = enda återvändo om
--    OpenAlex-svar visar sig felaktiga efter apply.
--
-- BAKGRUND (2026-08-25):
--
--   ORDER 155-auditen fångade 20 tomma journal i uncategorized-residualen.
--   Full-DB-räkning (ORDER 161) gav 356/35 107 = 1 % — mestadels konf-papers
--   från OpenAlex där primary_location.source.display_name var null.
--
--   ORDER 161 fixade pipelinen framåt (daily-fetch:626 fallback-kedja
--   primary_location.source → locations[].source). Denna backfill re-fetchar
--   redan-ingestade tomma-journal-rader från OpenAlex och applicerar samma
--   fallback-kedja så de blir identiska med vad pipelinen skulle skriva idag.
--
--   Källfördelning i populationen:
--     openalex          333  (re-fetch via OpenAlex ID eller DOI)
--     endnote            12  (kolla om url har DOI; annars skippa)
--     semantic_scholar   11  (kolla om url har DOI; annars skippa)
--     scopus              0  (redan täckt av prism:publicationName)
--     pubmed              0  (redan täckt av MedlineJournalInfo Title)
--
-- APPROACH:
--
--   Samma tabell-mönster som ORDER 149:s _backup, ORDER 153:s topic_backup
--   och ORDER 155:s irrelevant_backup. (article_id, value, snapshot_at, note).
--   value är text (tidigare journal-värde: null eller tom sträng).
--   PRIMARY KEY på article_id → safe re-run per note.
--
-- FÖRVÄNTAT ANTAL: ~356 rader (2026-08-25). Sanity RAISE WARNING vid avvikelse
--   > 20 % — pipeline kan ha lagt till/rensat rader sedan mätningen.
--
-- GRANTS: service_role skriver + läser. authenticated SELECT för framtida
--   admin-verktyg (samma mönster som topic_backup + irrelevant_backup).
-- =============================================================================


begin;
set local statement_timeout = '10min';


create table if not exists public.journal_backup (
  article_id   uuid        primary key,
  value        text,
  snapshot_at  timestamptz not null default now(),
  note         text
);

comment on table public.journal_backup is
  'Snapshot av articles.journal innan backfill. Rollback: UPDATE articles '
  'SET journal = backup.value FROM journal_backup backup '
  'WHERE articles.id = backup.article_id AND note = <note>.';


-- Snapshot bara rader med tomt journal-fält (matchar backfill-populationen).
-- NOT EXISTS-guarden gör migrationen idempotent per note vid re-run.
insert into public.journal_backup (article_id, value, note)
select a.id,
       a.journal,
       'pre ORDER 161 openalex journal-backfill'
  from public.articles a
 where (a.journal is null or trim(a.journal) = '')
   and a.irrelevant is not true
   and not exists (
     select 1 from public.journal_backup b
      where b.article_id = a.id
        and b.note = 'pre ORDER 161 openalex journal-backfill'
   );


-- Sanity: förvänta ~356 rader (mätt 2026-08-25). RAISE WARNING vid > 20 %
-- avvikelse; RAISE EXCEPTION endast om vi hamnar utanför en väldigt bred
-- gräns (pipeline kan ha lagt till/rensat rader sedan mätningen).
do $$ declare n int; begin
  select count(*) into n
    from public.journal_backup
   where note = 'pre ORDER 161 openalex journal-backfill';
  raise notice 'ORDER 161 backup: % rader snapshot:ade (förväntat ~356)', n;
  if n < 285 or n > 425 then
    raise warning 'ORDER 161: backup-antal % avviker >20%% från 356 — undersök innan backfill', n;
  end if;
  if n < 50 or n > 5000 then
    raise exception 'ORDER 161: backup-antal % långt utanför rimlig gräns — rullar tillbaka', n;
  end if;
end $$;


grant select, insert, update, delete on public.journal_backup to service_role;
grant select                          on public.journal_backup to authenticated;


commit;


-- =============================================================================
-- VERIFIERING EFTER APPLY (kör före backfill-scriptet):
--
--   -- 1. Antal rader i backup:
--   select count(*) from public.journal_backup
--    where note = 'pre ORDER 161 openalex journal-backfill';
--   -- expected: ~356
--
--   -- 2. Jämför mot articles direkt — ska matcha:
--   select
--     (select count(*) from public.articles
--       where (journal is null or trim(journal) = '') and irrelevant is not true) as articles_n,
--     (select count(*) from public.journal_backup
--       where note = 'pre ORDER 161 openalex journal-backfill')                    as backup_n;
--
--   -- 3. Alla värden är NULL eller tom sträng:
--   select coalesce(nullif(value, ''), '(null)') as v, count(*)
--     from public.journal_backup
--    where note = 'pre ORDER 161 openalex journal-backfill'
--    group by 1;
--   -- expected: bara "(null)" och/eller ""
-- =============================================================================


-- =============================================================================
-- ROLLBACK (om OpenAlex-svaren visar sig felaktiga efter backfill):
--
--   begin;
--   set local statement_timeout = '5min';
--
--   update public.articles a
--      set journal = b.value
--     from public.journal_backup b
--    where a.id = b.article_id
--      and b.note = 'pre ORDER 161 openalex journal-backfill';
--
--   select 'rollback: ' || count(*) || ' rader återställda till tomt journal'
--     from public.articles a
--     join public.journal_backup b
--       on a.id = b.article_id
--    where b.note = 'pre ORDER 161 openalex journal-backfill'
--      and coalesce(a.journal, '') = coalesce(b.value, '');
--
--   commit;
--
--   -- Ev. städa backup-raderna (om rollback är permanent):
--   -- delete from public.journal_backup
--   --  where note = 'pre ORDER 161 openalex journal-backfill';
-- =============================================================================
