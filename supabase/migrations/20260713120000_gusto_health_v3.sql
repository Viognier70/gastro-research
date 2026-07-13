-- gusto_health v3: lägg till TRIAD-signaler (takt + kö).
-- CREATE OR REPLACE VIEW för att bevara get_gusto_health()-funktionen
-- och grants (setof-returtypen påverkas inte av rena kolumn-tillägg
-- vid slutet — PG dokumenterar detta som tillåtet).
--
-- Två nya signaler:
--   triad_takt_24h  — rader där triad_completed_at satt senaste 24h.
--                     Kolumnen tillkom i migration 20260713110000; för
--                     historiska rader (9 234 st) är den NULL, vilket
--                     är precis vad vi vill — vi vet inte när de skrevs.
--                     Signalen startar på 0 och stiger naturligt.
--   triad_queue     — relevanta artiklar utan TRIAD (samma logik som
--                     sci_ko). ~26 300 rader just nu. Kön ska INTE tömmas —
--                     TRIAD är gated lazy caching (TRIAD_ENABLED=0 i
--                     pipeline) så bakgrundsjobbet mal ~48/dag mot 26k.
--                     Signalen är kanari, inte progress-mätare.

create or replace view public.gusto_health as
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
     ) as triad_misstankt_korta,

     -- v3 (2026-07-13): TRIAD-motorns egen takt + canary-kö.
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
