-- =====================================================================
-- gusto_health v5 — sci_ko matchar claim_pipeline_batch:s predikat
-- =====================================================================
-- v4:s sci_ko räknade "relevanta artiklar utan sci-scores":
--
--   count(*) from articles
--    where relevance_checked = true
--      and irrelevant = false
--      and relevance_sci_sensory_pro is null
--
-- Anders 2026-07-15: talet visade ~13k, men riktig claim-kö = 0.
-- Predikatet fångar rader som PIPELINE ALDRIG KAN CLAIMA:
--   - abstract IS NULL (Haiku behöver text att analysera)
--   - abstract för kort (< 50 tecken, pipeline skippar)
--   - saknas i processing_queue (aldrig enqueuead)
--
-- Väktaren larmar på sci_ko-tillväxt. Om räkningen sitter på 13k
-- när verklig kö är 0 blir hela signalen brus — permanent röd flagga
-- utan grund.
--
-- Nytt predikat: samma som claim_pipeline_batch — join mot
-- processing_queue.status='pending' AND sci_done=false, plus
-- abstract-krav på articles-sidan. Ger ~0 när pipeline hinner med
-- och stiger som en äkta claimable-kö.
--
-- (title-check tas separat: pipeline sätter status='skipped' med
-- last_error='title too short' — de raderna finns inte längre i
-- status='pending' och behöver därför inte filtreras här.)
--
-- Övriga signaler oförändrade från v4. Denna migration är ett
-- rent predikat-byte på en av 22 kolumner.
--
-- ORDNING (samma som v4): drop function → drop matview → create
-- matview → grants → create function → grants → refresh. Cron-
-- jobbet 'refresh_gusto_health_10m' är oförändrat och läser
-- matviewn efter namn.
-- =====================================================================

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

     -- v5-predikat: matchar claim_pipeline_batch exakt.
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

     -- v4-predikat (oförändrat): imrad-fyllda + relevance-checked + not
     -- irrelevant + kort på episteme_sensory_pro ELLER knowledge_explanation.
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
     ) as triad_queue
 )
 select kran_pct_med_inst, synt_rader, synt_unika, synt_senaste_alder_h,
        svep_gamla, svep_totalt, korpus_minar, korpus_maxar,
        abstract_kvar_att_hamta, abstract_takt_1h, affil_takt_1h, relevance_takt_1h,
        obedomd_ko, sci_ko, sci_takt_1h, sci_spoken, ko_failed,
        unika_doi, bedomt_relevanta, triad_misstankt_korta,
        triad_takt_24h, triad_queue
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

-- Initial refresh — cron 'refresh_gusto_health_10m' från v4 är oförändrat
-- och tickar var 10:e minut med samma jobname och SQL (refresh materialized
-- view public.gusto_health).
refresh materialized view public.gusto_health;

-- =====================================================================
-- Verifiering (efter apply):
--
--   -- 1. sci_ko nu ~0 (mot v4:s ~13k)
--   select sci_ko, bedomt_relevanta, obedomd_ko from public.get_gusto_health();
--
--   -- 2. Kontrasterat mot v4:s predikat: hur mycket sjönk räkningen?
--   select
--     (select count(*) from articles
--       where relevance_checked=true and irrelevant=false
--         and relevance_sci_sensory_pro is null)               as v4_sci_ko,
--     (select count(*) from processing_queue q join articles a on a.id=q.article_id
--       where q.status='pending' and q.sci_done=false
--         and a.irrelevant=false and a.abstract is not null
--         and length(a.abstract) > 50)                          as v5_sci_ko;
--
--   -- 3. Om v5_sci_ko ändå är stor (>1000) trots claim=0: RPC:n
--   --    filtrerar på nåt vi missat (attempts >= max? title-check?
--   --    FOR UPDATE SKIP LOCKED?). Justera predikatet därefter.
-- =====================================================================
