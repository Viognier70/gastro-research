-- gusto_health-vyn: dagligt hälsoblock för Väktaren-mailet (health-mail)
-- och realtidsalarm (health-alert). En rad, 20 signaler.
--
-- Vyn skapades ursprungligen manuellt i SQL Editor 2026-07-09 och levde
-- bara i produktion; git hade ingen definition. 2026-07-13 utökas den med
-- fem nya signaler (synt_senaste_alder_h, sci_ko, sci_takt_1h, sci_spoken,
-- ko_failed) och migreras hit så nästa gång är originalet i versionen.
--
-- get_gusto_health()-RPC:n används av health-mail via anon-JWT (SECURITY
-- DEFINER låser eskalering). Grants sätts explicit för anon/authenticated
-- /service_role.

drop function if exists public.get_gusto_health();
drop view if exists public.gusto_health;

create view public.gusto_health as
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

     ( select count(*) from articles
        where articles.relevance_checked = true
          and articles.irrelevant = false
          and articles.relevance_sci_sensory_pro is null
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
          and (
               length(coalesce(articles.imrad_introduction, '')) < 60
            or length(coalesce(articles.imrad_methods, '')) < 60
            or length(coalesce(articles.imrad_results, '')) < 60
            or length(coalesce(articles.imrad_discussion, '')) < 60
            or length(coalesce(articles.knowledge_explanation, '')) < 30
            or length(coalesce(articles.episteme_sensory_pro, '')) < 180
            or length(coalesce(articles.techne_sensory_pro, '')) < 180
            or length(coalesce(articles.phronesis_sensory_pro, '')) < 180
            or length(coalesce(articles.episteme_culinary_pro, '')) < 180
            or length(coalesce(articles.techne_culinary_pro, '')) < 180
            or length(coalesce(articles.phronesis_culinary_pro, '')) < 180
            or length(coalesce(articles.episteme_gastronomy_culture, '')) < 180
            or length(coalesce(articles.techne_gastronomy_culture, '')) < 180
            or length(coalesce(articles.phronesis_gastronomy_culture, '')) < 180
            or length(coalesce(articles.episteme_hospitality_mgmt, '')) < 180
            or length(coalesce(articles.techne_hospitality_mgmt, '')) < 180
            or length(coalesce(articles.phronesis_hospitality_mgmt, '')) < 180
            or length(coalesce(articles.episteme_educator_researcher, '')) < 180
            or length(coalesce(articles.techne_educator_researcher, '')) < 180
            or length(coalesce(articles.phronesis_educator_researcher, '')) < 180
          )
     ) as triad_misstankt_korta
 )
 select kran_pct_med_inst, synt_rader, synt_unika, synt_senaste_alder_h,
        svep_gamla, svep_totalt, korpus_minar, korpus_maxar,
        abstract_kvar_att_hamta, abstract_takt_1h, affil_takt_1h, relevance_takt_1h,
        obedomd_ko, sci_ko, sci_takt_1h, sci_spoken, ko_failed,
        unika_doi, bedomt_relevanta, triad_misstankt_korta
   from sig;

create or replace function public.get_gusto_health()
returns setof public.gusto_health
language sql
stable security definer
set search_path to 'public', 'pg_temp'
set statement_timeout to '30s'
as $health$
  select * from public.gusto_health limit 1;
$health$;

grant select on public.gusto_health to anon, authenticated, service_role;
grant execute on function public.get_gusto_health() to anon, authenticated, service_role;
