-- =============================================================================
-- ORDER 148 — gusto_health v6: veckobrev_alder_h + veckobrev_kandidater
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- ⚠️  KÖR 20260824150000_weekly_digest_runs_table.sql FÖRST — vyn refererar
--    public.weekly_digest_runs som skapas där.
--
-- BAKGRUND (2026-08-24):
--
--   send-weekly-digest schemalagd via GHA måndagar 06:00 UTC (ORDER 148).
--   Utan integration i väktaren är scheduler-hälsan tyst — samma klass som
--   daily-fetch:s TOPICS-fallback jag noterade i minnet. Två nya signaler:
--
--     veckobrev_alder_h    — timmar sedan senast lyckade körning
--                            (max finished_at where fatal_error is null).
--                            NULL om aldrig lyckats.
--     veckobrev_kandidater — antal profiler som VILL få digest (role IS NOT NULL
--                            AND digest_enabled IS TRUE). Matchar fetchRecipients-
--                            filtret minus 6-dygns cooldown (irrelevant här —
--                            om takt är gammal har cooldown gått ut).
--
--   Anti-takt-utan-kö-mönstret (memory: feedback_takt_utan_ko.md): paras
--   alltid. veckobrev_alder_h=NULL + veckobrev_kandidater=0 är ett rimligt
--   nolltillstånd (ingen prenumererar). veckobrev_alder_h=200h + kandidater=5
--   är signal för digest_stalled — health-alert edge-fn triggar SMS.
--
-- ÖVRIGA SIGNALER OFÖRÄNDRADE från v5 (20260715150000). Detta är rent
-- additiv utökning: 22 → 24 kolumner. get_gusto_health()-signaturen
-- följer med automatiskt (returnerar setof public.gusto_health).
--
-- ORDNING (samma som v4/v5): drop function → drop matview → create matview
-- → grants → create function → grants → refresh. Cron 'refresh_gusto_health_10m'
-- är oförändrat och läser matviewn efter namn.
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
     -- BARA när alder_h är stor OCH kandidater > 0. NULL alder = aldrig
     -- kört lyckat = larmar inte (första körningen: se GHA-workflow UI).
     ( select round((extract(epoch from now() - max(finished_at)) / 3600.0)::numeric)
         from public.weekly_digest_runs
        where fatal_error is null
     ) as veckobrev_alder_h,

     ( select count(*) from public.profiles
        where role is not null
          and digest_enabled is true
     ) as veckobrev_kandidater
 )
 select kran_pct_med_inst, synt_rader, synt_unika, synt_senaste_alder_h,
        svep_gamla, svep_totalt, korpus_minar, korpus_maxar,
        abstract_kvar_att_hamta, abstract_takt_1h, affil_takt_1h, relevance_takt_1h,
        obedomd_ko, sci_ko, sci_takt_1h, sci_spoken, ko_failed,
        unika_doi, bedomt_relevanta, triad_misstankt_korta,
        triad_takt_24h, triad_queue,
        veckobrev_alder_h, veckobrev_kandidater
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
--   select veckobrev_alder_h, veckobrev_kandidater from public.get_gusto_health();
--   -- expected: alder_h = NULL (ingen körning ännu), kandidater > 0
--
--   -- 2. Signal blir non-null när första lyckade körningen skrivits:
--   insert into public.weekly_digest_runs (triggered_by, finished_at)
--     values ('manual-smoke', now());
--   select public.refresh_map_mvs();  -- ⚠️ INTE räckt — vi behöver bara refresh gusto_health:
--   refresh materialized view public.gusto_health;
--   select veckobrev_alder_h from public.get_gusto_health();
--   -- expected: 0 (nu just skrivet)
--
--   -- Städa smoke-raden:
--   delete from public.weekly_digest_runs where triggered_by = 'manual-smoke';
--   refresh materialized view public.gusto_health;
--
--   -- 3. Andra kolumner oförändrade — sci_ko, bedomt_relevanta etc:
--   select sci_ko, bedomt_relevanta, obedomd_ko from public.get_gusto_health();
--   -- expected: samma värden som v5-mätning
-- =============================================================================
