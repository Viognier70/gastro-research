-- =====================================================================
-- gusto_health v4 — matview + rättad triad_misstankt_korta-canary
-- =====================================================================
-- Två samverkande ändringar; båda löser problem som yttrade sig som
-- tyst buller i Väktaren.
--
-- ÄNDRING 1 — predikatet för triad_misstankt_korta.
--
--   v3-formeln matchade rader där imrad_methods finns OCH något
--   TRIAD-fält är kort/tomt. coalesce('') < 180 fires på NULL, så
--   raden räknades så fort en science-kolumn var NULL — även för
--   rader som fick IMRaD innan relevansfiltret lagades och som
--   ALDRIG kommer analyseras (irrelevant = true), eller rader som
--   ännu inte gått igenom screening.
--
--   Anders 2026-07-14: 1 306 av de 1 618 misstänkta är imrad-only-
--   irrelevanta som aldrig ska repareras. En signal som permanent
--   står på 1 618 lär oss ingenting.
--
--   Nytt predikat kräver att raden är:
--     - IMRaD-fylld (pipeline nått TRIAD-steget)
--     - relevance_checked = true (screening klar)
--     - irrelevant = false (vi vill analysera den)
--     - kort på episteme_sensory_pro ELLER knowledge_explanation
--
--   Ger 312 vid apply. Talet sjunker mot 0 när TRIAD-motorn maler
--   ner kön och stiger när något går sönder. Signal, inte buller.
--
--   Varför bara två OR-fält (inte alla 15 TRIAD-kolumner)? TRIAD
--   skriver atomärt över alla fem roller × tre axlar — om ett
--   science-fält är kort är alla suspekta. episteme_sensory_pro är
--   den kanoniska proxyn sedan pipeline-övergången (samma val i
--   sci_ko och triad_queue). knowledge_explanation är en oberoende
--   sanning — TRIAD kan ha kört utan att metadata-fältet skrevs.
--   Två breda kanariefåglar räcker; alla 15 blir statistiskt buller
--   utan mer information.
--
-- ÄNDRING 2 — matview + refresh var 10:e minut.
--
--   Vyn räknar 22 aggregat över articles (456k rader). EXPLAIN
--   visar 8-12 s exekvering. Anon-anrop mot get_gusto_health()
--   timeoutade 2026-07-14 kl 12:00 med 57014 (samma symptom som
--   dödade tratten i morse — screening_funnel v1).
--
--   Fix: samma pattern som screening_funnel (20260713130000) —
--   materialized view + pg_cron '*/10 * * * *'. Ingen CONCURRENTLY
--   (en rad, snabb lås). Läsare (health-mail dagligen, health-alert
--   var 30:e min) tolererar 10 minuters fördröjning.
--
-- ORDNING — kritiskt.
--   get_gusto_health() returnerar SETOF public.gusto_health. Byte
--   av typ (view → matview) kräver att funktionen droppas först.
--   Anders (2026-07-14, morse): försökte cascade — vyn vägrade.
--   Rätt sekvens:
--     1. drop function get_gusto_health()
--     2. drop view gusto_health   (eller drop matview om partiell)
--     3. create materialized view gusto_health
--     4. create function get_gusto_health() returns setof gusto_health
--     5. grants + initial refresh + cron
--
-- SÄKERHET
--   Matviews stöder inte RLS. Innehållet är aggregat (räkningar,
--   procent, min/max år) — inga ID:n, inga texter, ingen radnivådata.
--   Grant select till anon+authenticated är säkert.
--
--   Supabase default alter default privileges ger anon+authenticated
--   arwdDxtm på nya relationer. MAINTAIN (m, PG17+) skulle låta anon
--   köra REFRESH → 10+ s DoS per anrop. revoke all → grant select.
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

     -- v4-predikat (se doc-block överst för motivering).
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

-- Initial refresh — utan detta ligger matviewn tom mellan CREATE och
-- första cron-tick (upp till 10 minuter).
refresh materialized view public.gusto_health;

-- Idempotent: cron.schedule med samma jobname replacer existerande.
select cron.schedule(
  'refresh_gusto_health_10m',
  '*/10 * * * *',
  $CRON$refresh materialized view public.gusto_health;$CRON$
);

-- =====================================================================
-- Verifiering (efter apply):
--
--   -- 1. Matview finns, får läsas som anon, 22 kolumner
--   select * from public.get_gusto_health();
--   -- expected: 1 rad, 22 kolumner, triad_misstankt_korta ≈ 312
--
--   -- 2. Cron-job aktiverad
--   select jobid, jobname, schedule, active
--     from cron.job
--    where jobname = 'refresh_gusto_health_10m';
--   -- expected: 1 rad, active = true, schedule = '*/10 * * * *'
--
--   -- 3. Refresh-status
--   select status, return_message, start_time, end_time
--     from cron.job_run_details
--    where jobid = (select jobid from cron.job
--                    where jobname = 'refresh_gusto_health_10m')
--    order by start_time desc limit 5;
--   -- expected: status='succeeded', end_time - start_time < 30s
-- =====================================================================
