-- =============================================================================
-- ORDER 175 — gusto_health v7: citations_alder_h + citations_backlog
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- ⚠️  KÖR 20260826140000_citation_updates_runs_table.sql FÖRST — vyn refererar
--    public.citation_updates_runs som skapas där.
--
-- BAKGRUND (2026-08-26):
--
--   backfill-citation-counts schemalagd via GHA måndag + torsdag 06:00 UTC
--   (ORDER 175 pt 4). Utan integration i väktaren är scheduler-hälsan tyst
--   — samma klass som ORDER 148:s veckobrev. Två nya signaler:
--
--     citations_alder_h — timmar sedan senast lyckade körning
--                         (max finished_at from citation_updates_runs where
--                         fatal_error is null). NULL om aldrig lyckats.
--     citations_backlog — antal articles utan citation_count-värde OCH med
--                         en lookup-nyckel (OpenAlex-ID eller DOI i url).
--                         Om schemat pausas växer denna monotont; annars
--                         plataserar den runt icke-tåtbara rader.
--
--   Anti-takt-utan-kö-mönstret (memory: feedback_takt_utan_ko.md): paras
--   alltid. citations_alder_h=NULL + citations_backlog=0 är rimligt noll-
--   tillstånd (allt gjort). citations_alder_h=100h + backlog=10000 är signal
--   för citations_stalled — health-alert edge-fn triggar SMS.
--
--   Baseline mätning 2026-08-26: citation_count > 0 = 123/35 141, dvs
--   backlog ~35 018 innan första körning. Efter första lyckade run är
--   backlog ~1500-2000 (rader utan lookup-nyckel — endnote-imports utan
--   DOI). Alla efterföljande run:s ska hålla samma nivå ± små drift.
--
-- ÖVRIGA SIGNALER OFÖRÄNDRADE från v6 (20260824160000). Detta är rent
--   additiv utökning: 24 → 26 kolumner. get_gusto_health()-signaturen
--   följer med automatiskt (returnerar setof public.gusto_health).
--
-- ORDNING: drop function → drop matview → create matview → grants →
--   create function → grants → refresh. Cron 'refresh_gusto_health_10m'
--   är oförändrat och läser matviewn efter namn.
-- =============================================================================


drop function if exists public.get_gusto_health();

do $$
begin
  if exists (select 1 from pg_class
              where relnamespace = 'public'::regnamespace
                and relname = 'gusto_health' and relkind = 'v') then
    execute 'drop view public.gusto_health';
  elsif exists (select 1 from pg_class
                 where relnamespace = 'public'::regnamespace
                   and relname = 'gusto_health' and relkind = 'm') then
    execute 'drop materialized view public.gusto_health';
  end if;
end $$;


create materialized view public.gusto_health as
 with sig as (
   select
     ( select round(100.0 * count(*) filter (where articles.institutions is not null)::numeric
                    / nullif(count(*), 0)::numeric, 1)
         from articles
        where articles.fetched_at > (now() - interval '24 hours')
     ) as kran_pct_med_inst,

     ( select count(*) from research_syntheses ) as synt_rader,

     ( select count(distinct row(research_syntheses.role, research_syntheses.topic))
         from research_syntheses ) as synt_unika,

     ( select round((extract(epoch from now() - max(coalesce(research_syntheses.updated_at, research_syntheses.created_at))) / 3600.0)::numeric)
         from research_syntheses ) as synt_senaste_alder_h,

     ( select count(*) from backfill_progress
        where backfill_progress.completed = false
          and backfill_progress.last_run < (now() - interval '24 hours')
     ) as svep_gamla,

     ( select count(*) from backfill_progress
        where backfill_progress.completed = false ) as svep_totalt,

     ( select min(articles.year) from articles
        where articles.relevance_checked = true and articles.irrelevant = false
     ) as korpus_minar,

     ( select max(articles.year) from articles
        where articles.relevance_checked = true and articles.irrelevant = false
     ) as korpus_maxar,

     ( select count(*) from articles
        where articles.abstract is null
          and articles.abstract_attempted_at is null
          and articles.url ilike '%doi.org%'
     ) as abstract_kvar_att_hamta,

     ( select count(*) from articles
        where articles.abstract_attempted_at > (now() - interval '1 hour')
     ) as abstract_takt_1h,

     ( select count(*) from articles
        where articles.affiliation_attempted_at > (now() - interval '1 hour')
     ) as affil_takt_1h,

     ( select count(*) from articles
        where articles.relevance_checked_at > (now() - interval '1 hour')
     ) as relevance_takt_1h,

     ( select count(*) from articles
        where articles.relevance_checked = false
     ) as obedomd_ko,

     ( select count(*)
         from processing_queue q
         join articles a on a.id = q.article_id
        where q.status = 'pending'
          and q.sci_done = false
          and a.irrelevant = false
          and a.abstract is not null
          and length(a.abstract) > 50
     ) as sci_ko,

     ( select count(*) from processing_queue q
         join articles a on a.id = q.article_id
        where q.updated_at > (now() - interval '1 hour')
          and q.sci_done = true
          and a.relevance_sci_sensory_pro is not null
     ) as sci_takt_1h,

     ( select count(*) from processing_queue q
         join articles a on a.id = q.article_id
        where q.sci_done = true
          and a.relevance_sci_sensory_pro is null
     ) as sci_spoken,

     ( select count(*) from processing_queue
        where processing_queue.status = 'failed'
     ) as ko_failed,

     ( select count(distinct nullif(regexp_replace(articles.url, '.*doi\.org/', ''), ''))
         from articles
        where articles.url ilike '%doi.org%'
     ) as unika_doi,

     ( select count(*) from articles
        where articles.relevance_checked = true and articles.irrelevant = false
     ) as bedomt_relevanta,

     ( select count(*) from articles
        where articles.imrad_methods is not null
          and articles.relevance_checked = true
          and articles.irrelevant = false
          and (
               length(coalesce(articles.episteme_sensory_pro, '')) < 180
            or length(coalesce(articles.knowledge_explanation, '')) < 30
          )
     ) as triad_misstankt_korta,

     ( select count(*) from articles
        where articles.triad_completed_at > (now() - interval '24 hours')
     ) as triad_takt_24h,

     ( select count(*) from articles
        where articles.relevance_checked = true
          and articles.irrelevant = false
          and articles.phronesis_educator_researcher is null
     ) as triad_queue,

     -- ORDER 148 (2026-08-24): veckobrev-signalerna. Paras alltid takt+kö
     -- per feedback_takt_utan_ko.md — health-alert digest_stalled larmar
     -- BARA när alder_h är stor OCH kandidater > 0.
     ( select round((extract(epoch from now() - max(finished_at)) / 3600.0)::numeric)
         from public.weekly_digest_runs
        where fatal_error is null
     ) as veckobrev_alder_h,

     ( select count(*) from public.profiles
        where role is not null
          and digest_enabled is true
     ) as veckobrev_kandidater,

     -- ORDER 175 (2026-08-26): citation-backfill-signalerna. Paras alltid
     -- takt+backlog per feedback_takt_utan_ko.md — health-alert
     -- citations_stalled larmar BARA när alder_h > 96 (missad Mon+Thu-slot
     -- + halv dag) OCH backlog > 5000 (godtycklig tröskel över den
     -- långsiktiga plataserings-nivån på ~1500-2000 rader utan lookup-
     -- nyckel).
     ( select round((extract(epoch from now() - max(finished_at)) / 3600.0)::numeric)
         from public.citation_updates_runs
        where fatal_error is null
     ) as citations_alder_h,

     -- Backlog = articles utan citation_count OCH med en lookup-nyckel
     -- (OpenAlex-ID eller DOI i url). Räknas mot irrelevant is not true —
     -- vi backfillar inte skräp.
     ( select count(*) from public.articles
        where (citation_count is null or citation_count = 0)
          and irrelevant is not true
          and url is not null
          and (url ~ 'openalex\.org/W\d+' or url ilike '%doi.org%')
     ) as citations_backlog
 )
 select kran_pct_med_inst, synt_rader, synt_unika, synt_senaste_alder_h,
        svep_gamla, svep_totalt, korpus_minar, korpus_maxar,
        abstract_kvar_att_hamta, abstract_takt_1h, affil_takt_1h, relevance_takt_1h,
        obedomd_ko, sci_ko, sci_takt_1h, sci_spoken, ko_failed,
        unika_doi, bedomt_relevanta, triad_misstankt_korta,
        triad_takt_24h, triad_queue,
        veckobrev_alder_h, veckobrev_kandidater,
        citations_alder_h, citations_backlog
   from sig;


revoke all on public.gusto_health from anon, authenticated;
grant select on public.gusto_health to anon, authenticated, service_role;


create or replace function public.get_gusto_health()
returns setof public.gusto_health
language sql
stable security definer
set search_path to 'public', 'pg_temp'
set statement_timeout to '30s'
as $health$
  select * from public.gusto_health limit 1;
$health$;

grant execute on function public.get_gusto_health() to anon, authenticated, service_role;

-- Initial refresh — cron 'refresh_gusto_health_10m' från v4 tickar
-- var 10:e minut med samma jobname och SQL (refresh materialized view
-- public.gusto_health). Ingen ändring behövs på cron.
refresh materialized view public.gusto_health;


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Nya kolumnerna finns:
--   select column_name from information_schema.columns
--    where table_schema = 'public' and table_name = 'gusto_health'
--      and column_name in ('citations_alder_h', 'citations_backlog');
--   -- expected: 2 rader
--
--   -- 2. Signalerna kan läsas:
--   select citations_alder_h, citations_backlog from public.get_gusto_health();
--   -- expected: alder_h = NULL (första gången — inga rader i citation_updates_runs),
--   --           backlog ≈ 35 000 (baseline innan första run — kan variera)
--
--   -- 3. Efter första lyckade run:
--   -- alder_h ≈ 0 (nyss körd), backlog ≈ 1500-2000 (rader utan lookup-nyckel).
-- =============================================================================
