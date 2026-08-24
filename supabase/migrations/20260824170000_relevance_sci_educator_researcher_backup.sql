-- =============================================================================
-- ORDER 149 — snapshot av relevance_sci_educator_researcher innan v-d rescore
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- ⚠️  KÖR DENNA MIGRATION FÖRE `scripts/batch-regen-sci.ts --apply`.
--    Utan snapshot försvinner alla 45,217 gamla värden vid UPDATE.
--    Se rollback-block i slutet av denna fil.
--
-- BAKGRUND (2026-08-24):
--
--   ORDER 149 v-d (commit 1f3246a) uppdaterade prompten som scorar
--   relevance_sci_educator_researcher. Sample-verifikation visade sig
--   godkänd (100-sample: 9-10-band = 3 rader metod-som-ämne + pedagogy,
--   klump 7 = 48/100 vs tidigare 100% på 9 i DB).
--
--   Skarp körning (batch-regen-sci.ts --apply) skriver om 45,217 rader
--   med single-column UPDATE på educator-kolumnen. Ingen rollback-väg
--   finns i script:et själv. Denna migration är den enda återvändo-
--   möjligheten om v-d skulle visa sig fel efter apply.
--
-- APPROACH:
--
--   Enkel snapshot-tabell med (article_id, value, snapshot_at, note).
--   PRIMARY KEY på article_id — en rad per artikel som backupas. Note-
--   fältet fritt så framtida backupar (från annan roll eller annan
--   prompt-revision) kan samexistera med olika note-värden.
--
--   INSERT själv körs i samma transaktion. Om något går sönder mitt-
--   INSERT rullas tabell-skapandet också tillbaka.
--
-- FÖRVÄNTAT ANTAL: 45,217 rader (mätt via articles_public 2026-08-24).
--   Sanity-checken efter INSERT skriver RAISE WARNING om avvikelse.
--
-- GRANTS: service_role skriver + läser (batch-regen-scriptet och
--   rollback-flödet). authenticated SELECT för framtida admin-verktyg
--   (matchar mönstret från weekly_digest_runs i ORDER 148).
-- =============================================================================


begin;
set local statement_timeout = '10min';


create table if not exists public.relevance_sci_educator_researcher_backup (
  article_id   uuid primary key,
  value        int,
  snapshot_at  timestamptz not null default now(),
  note         text
);

comment on table public.relevance_sci_educator_researcher_backup is
  'ORDER 149: snapshot av relevance_sci_educator_researcher innan v-d '
  'rescore. Rollback: UPDATE articles SET relevance_sci_educator_researcher '
  '= backup.value FROM backup WHERE articles.id = backup.article_id.';


insert into public.relevance_sci_educator_researcher_backup
  (article_id, value, note)
select id,
       relevance_sci_educator_researcher,
       'pre ORDER 149 v-d rescore'
from public.articles
where relevance_sci_educator_researcher is not null;


-- Sanity: förvänta 45,217 rader (±5% för pipeline-drift senaste dygnet).
do $$ declare n int; begin
  select count(*) into n from public.relevance_sci_educator_researcher_backup
   where note = 'pre ORDER 149 v-d rescore';
  raise notice 'ORDER 149 backup: % rader snapshotade (förväntat ~45217)', n;
  if n < 43000 or n > 47000 then
    raise warning 'ORDER 149: backup-antal % avviker från 45217 — undersök innan batch', n;
  end if;
end $$;


-- service_role skriver, authenticated läser (framtida admin-verktyg)
grant select, insert, update, delete on public.relevance_sci_educator_researcher_backup
  to service_role;
grant select on public.relevance_sci_educator_researcher_backup to authenticated;


commit;


-- =============================================================================
-- VERIFIERING EFTER APPLY (kör före batch-regen):
--
--   -- 1. Antal rader i backup (målvärde ~45,217):
--   select count(*) from public.relevance_sci_educator_researcher_backup
--    where note = 'pre ORDER 149 v-d rescore';
--
--   -- 2. Jämför mot articles direkt — ska matcha exakt:
--   select
--     (select count(*) from public.articles
--       where relevance_sci_educator_researcher is not null) as articles_n,
--     (select count(*) from public.relevance_sci_educator_researcher_backup
--       where note = 'pre ORDER 149 v-d rescore')            as backup_n;
--   -- expected: identiska
--
--   -- 3. Distributionen som ska ersättas (för att jämföra mot efter-rescore):
--   select value, count(*) as n
--     from public.relevance_sci_educator_researcher_backup
--    where note = 'pre ORDER 149 v-d rescore'
--    group by value
--    order by value desc;
-- =============================================================================


-- =============================================================================
-- ROLLBACK (om v-d visar sig fel efter batch-regen):
--
--   begin;
--   set local statement_timeout = '15min';
--
--   update public.articles a
--      set relevance_sci_educator_researcher = b.value
--     from public.relevance_sci_educator_researcher_backup b
--    where a.id = b.article_id
--      and b.note = 'pre ORDER 149 v-d rescore';
--
--   -- Bekräfta antalet återställda rader = ~45217
--   select 'rollback: ' || count(*) || ' rader återställda'
--     from public.articles a
--     join public.relevance_sci_educator_researcher_backup b
--       on a.id = b.article_id
--    where b.note = 'pre ORDER 149 v-d rescore'
--      and a.relevance_sci_educator_researcher = b.value;
--
--   commit;
--
--   -- Ev. städa backup-raderna (om rollback är permanent):
--   -- delete from public.relevance_sci_educator_researcher_backup
--   --  where note = 'pre ORDER 149 v-d rescore';
-- =============================================================================
