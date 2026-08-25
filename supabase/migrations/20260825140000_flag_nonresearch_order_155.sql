-- =============================================================================
-- ORDER 155 — flagga tre icke-forsknings-rader som irrelevant
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- BAKGRUND (2026-08-25):
--
--   Efter ORDER 153 (Haiku-klassificering av 3,714 uncategorized) +
--   ORDER 154 (parse-error rescue av 91 rader) ligger 218 rader kvar i
--   articles.topic='uncategorized' AND irrelevant IS NOT TRUE.
--
--   Publikationstyp-auditen (out/uncategorized-pubtype-audit.md, körd
--   2026-08-25 via scripts/audit-uncategorized-pubtype.ts) visade att
--   216/218 har DOI-URL, 209 har IMRaD, 215 har study_type — de är
--   forskning enligt DOI/IMRaD/study_type-signalerna, bara inte
--   gastronomi. Uncategorized är därför acceptabelt för dessa; de
--   ligger kvar utan flaggning.
--
--   TRE rader är däremot INTE forskning enligt regeln "peer-reviewad
--   eller på annat sätt en vetenskaplig publikation":
--
--     * d25b95c3  College & Research Libraries News (ACRL:s
--                 medlemsmagasin, skiljt från peer-review-tidskriften
--                 *College & Research Libraries*)
--     * d345e03b  The Sociological Review Magazine (podcast/essä-
--                 spinoff från peer-review-tidskriften *The
--                 Sociological Review*; titeln är samtal, inte artikel)
--     * d8e68b73  Africa Review of Books (boksrecensionstidskrift;
--                 titeln är själva utgåvenumret som scrapad metadata)
--
--   Denna migration flippar irrelevant=true för dessa tre. Snapshot
--   av tidigare värde sparas i irrelevant_backup för spårbarhet och
--   rollback. Endast tre rader men irrelevant-flaggan döljer material
--   från hela produkten (feed, sök, TRIAD, digest) och bör vara
--   spårbar även för små ingrepp.
--
-- APPROACH:
--
--   Samma tabell-mönster som ORDER 149:s _backup och ORDER 153:s
--   topic_backup: (article_id, value, snapshot_at, note). value är
--   boolean (tidigare irrelevant-status, typiskt false eller NULL).
--   PRIMARY KEY på article_id gör tabellen safe för re-run per note.
--
--   UPDATE-filtret innehåller redundanta villkor
--     * id-prefix (8 tecken från audit-rapporten)
--     * topic = 'uncategorized' (post-ORDER-154-status)
--     * coalesce(irrelevant, false) = false (idempotens: re-run gör inget)
--   för att raden ska matcha exakt en gång. Sanity-check n=3 fångar
--   avvikelser (ex. om någon rad hunnit flyttas från uncategorized
--   sedan auditen).
--
-- FÖRVÄNTAT ANTAL: exakt 3 rader. Sanity-checken hävar (RAISE
--   EXCEPTION) vid n != 3 så transaktionen rullas tillbaka.
--
-- GRANTS: service_role skriver + läser. authenticated SELECT för
--   framtida admin-verktyg (samma mönster som topic_backup).
-- =============================================================================


begin;
set local statement_timeout = '5min';


create table if not exists public.irrelevant_backup (
  article_id   uuid        primary key,
  value        boolean,
  snapshot_at  timestamptz not null default now(),
  note         text
);

comment on table public.irrelevant_backup is
  'Snapshot av articles.irrelevant innan flag-flip. Rollback: '
  'UPDATE articles SET irrelevant = backup.value FROM irrelevant_backup '
  'backup WHERE articles.id = backup.article_id AND note = <note>.';


-- Snapshot av de tre radernas nuvarande irrelevant-värde (typiskt
-- NULL eller false). Bara nya rader tas — NOT EXISTS-guarden gör
-- migrationen idempotent per note vid re-run.
insert into public.irrelevant_backup (article_id, value, note)
select a.id,
       a.irrelevant,
       'pre ORDER 155 nonresearch flag'
  from public.articles a
 where (a.id::text like 'd25b95c3%'
     or a.id::text like 'd345e03b%'
     or a.id::text like 'd8e68b73%')
   and a.topic = 'uncategorized'
   and coalesce(a.irrelevant, false) = false
   and not exists (
     select 1 from public.irrelevant_backup b
      where b.article_id = a.id
        and b.note = 'pre ORDER 155 nonresearch flag'
   );


-- Flippa irrelevant=true för de tre. Samma filter som INSERT ovan
-- så snapshot och UPDATE alltid täcker samma rader.
update public.articles a
   set irrelevant = true
 where (a.id::text like 'd25b95c3%'
     or a.id::text like 'd345e03b%'
     or a.id::text like 'd8e68b73%')
   and a.topic = 'uncategorized'
   and coalesce(a.irrelevant, false) = false;


-- Sanity: förvänta exakt 3 rader flaggade (eller 0 vid re-run efter
-- första apply). Allt annat är avvikelse — rulla tillbaka och undersök.
do $$ declare n int; begin
  select count(*) into n
    from public.irrelevant_backup
   where note = 'pre ORDER 155 nonresearch flag';
  raise notice 'ORDER 155: % rader snapshot:ade + flaggade som irrelevant', n;
  if n <> 3 then
    raise exception 'ORDER 155: förväntat exakt 3 rader, fick %. Rullar tillbaka.', n;
  end if;
end $$;


grant select, insert, update, delete on public.irrelevant_backup to service_role;
grant select                          on public.irrelevant_backup to authenticated;


commit;


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. De tre är flaggade:
--   select id, journal, topic, irrelevant
--     from public.articles
--    where id::text like 'd25b95c3%'
--       or id::text like 'd345e03b%'
--       or id::text like 'd8e68b73%';
--   -- expected: 3 rader, alla irrelevant = true, topic fortfarande 'uncategorized'
--
--   -- 2. Uncategorized-residualen krymper med exakt 3:
--   select count(*) from public.articles
--    where topic = 'uncategorized' and irrelevant is not true;
--   -- expected: 215 (var 218 före apply)
--
--   -- 3. Backup innehåller de tre med rätt note:
--   select article_id, value, note
--     from public.irrelevant_backup
--    where note = 'pre ORDER 155 nonresearch flag';
--   -- expected: 3 rader
-- =============================================================================


-- =============================================================================
-- ROLLBACK (om något av de tre visar sig vara felbedömt):
--
--   begin;
--   set local statement_timeout = '2min';
--
--   update public.articles a
--      set irrelevant = b.value
--     from public.irrelevant_backup b
--    where a.id = b.article_id
--      and b.note = 'pre ORDER 155 nonresearch flag';
--
--   select 'rollback: ' || count(*) || ' rader återställda'
--     from public.articles a
--     join public.irrelevant_backup b
--       on a.id = b.article_id
--    where b.note = 'pre ORDER 155 nonresearch flag'
--      and coalesce(a.irrelevant, false) = coalesce(b.value, false);
--
--   commit;
--
--   -- Ev. städa backup-raderna (om rollback är permanent):
--   -- delete from public.irrelevant_backup
--   --  where note = 'pre ORDER 155 nonresearch flag';
-- =============================================================================


-- =============================================================================
-- TEKNISK SKULD (uppskjuten från ORDER 155):
--
--   Auditen visade 20 rader med tomt journal-fält som alla har DOI-URL,
--   IMRaD och study_type — de är forskning men journalnamnet gick
--   förlorat vid ingest. Mönstret matchar OpenAlex conf-papers och en
--   del open-access-arkiv där host_venue.display_name saknas men
--   primary_location.source.display_name finns.
--
--   Fixen ska ske vid källan i daily-fetch/index.ts (openalex-branchen
--   runt rad 639) — läs primary_location.source.display_name som
--   fallback när w.host_venue?.display_name är tomt. Backfilla INTE
--   enskilda rader; vänta tills källfixen är på plats och kör om
--   ingesten för de 20 vid behov.
--
--   Effekt på ORDER 155:s flag-beslut: noll. Raderna klassas som
--   forskning oavsett (DOI + IMRaD + study_type räcker enligt regeln).
-- =============================================================================
