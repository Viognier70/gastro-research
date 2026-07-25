-- =============================================================================
-- Cron-fixar: triad_background_30m + reset-stuck (2026-07-25)
-- =============================================================================
-- Redan applicerat mot prod idag. KÖR INTE MOT PROD — för git-paritet.
--
-- BAKGRUND:
--
--   1. triad_background_30m innehöll texten '<samma struktur, men mot
--      triad-background>' som SQL-kommando — en platshållare som aldrig
--      byttes ut mot riktig kod. Jobbet var scheduled men exekverade
--      aldrig något meningsfullt. Dött från 2026-07-23 12:30 till
--      2026-07-25 13:00 — 97 misslyckade tick.
--
--      Ingen larmade eftersom health_alert_30m inte läser
--      cron.job_run_details.status. Väktaren har alltså en blind fläck
--      för cron-fel: den ser köhälsa och latens, inte scheduler-fel.
--      Backlog: låt health-alert plocka upp status='failed'-rader från
--      cron.job_run_details senaste timmen.
--
--      Schemat ändrades samma dag från '*/30' till '*/5'. Orsak:
--      Sonnet-latensen gör att varje invocation hinner få tag på
--      artiklar inom HARD_TIMEOUT (100s), så kapaciteten sitter i
--      antal invocations per tidsenhet, inte i batchstorlek per
--      invocation. TRIAD_DAILY_BUDGET höjdes samtidigt 50 → 300 via
--      Supabase secret (ingen kodändring i triad-background). Jobbnamnet
--      säger fortfarande '30m' vilket nu är vilseledande — byt vid
--      tillfälle till 'triad_background_5m' (och glöm inte att också
--      unschedule det gamla, annars dubblas invocations).
--
--   2. reset-stuck (bindestreck, INTE underscore — reset_stuck ger noll
--      rader i cron.job) misslyckades 288 gånger sedan constraintet
--      status_done_requires_both_flags infördes (20260715160000). Roten
--      låg i den ANDRA av tre UPDATE-satser: `SET status='done' WHERE
--      attempts>=5` bröt constraintet — 'done' kräver att både sci_done
--      och triad_done är true, men attempts>=5-vägen aktiverar sig när
--      de INTE är det.
--
--      Eftersom alla tre UPDATE-satserna kör i samma transaktion
--      rullades HELA jobbet tillbaka på 23514. Sats 1 (processing →
--      pending efter 6 min timeout) och sats 3 (done när båda flaggor
--      är true — legitim och orörd) gjorde alltså inte heller något
--      på 288 körningar. Fixad: sats 2 sätter nu 'failed', vilket är
--      den korrekta semantiken för "gav upp efter 5 försök".
--
-- FÖRUTSÄTTNING FÖR GIT-PARITET:
--
--   Cron-jobben ligger inte i git sedan tidigare (skapade orphan direkt
--   i prod, samma mönster som get_role_centroid + get_most_cited innan
--   de adopterades). Definitionerna nedan är ordagrant hämtade från
--   prod 2026-07-25 EFTER båda fixarna:
--
--     select jobname, schedule, command
--       from cron.job
--      where jobname in ('triad_background_30m', 'reset-stuck');
--
--   cron.schedule med samma jobname replacer existerande schedule
--   idempotent, så det spelar ingen roll att jobben redan finns i prod.
-- =============================================================================


-- =============================================================================
-- 1. triad_background_30m — POSTar till edge fn triad-background var
--    5:e min (schemat höjt från */30 samma dag, se header). Samma
--    vault-mönster som trigger_health_alert / trigger_health_mail /
--    trigger_backfill_abstracts (2026-07-09 och -10), men här inline
--    i cron-kommandot i stället för via en wrapper-funktion. Det är den
--    historiska varianten — konsekvens av att jobbet skapades orphan
--    innan wrapper-mönstret etablerades. Jobbnamnet innehåller '30m'
--    men schedule är nu '*/5' — vilseledande, byt vid tillfälle.
-- =============================================================================

select cron.schedule(
  'triad_background_30m',
  '*/5 * * * *',
  $CRON$
  SELECT net.http_post(
    url:='https://igmkzhdovyhbfgjomrsc.supabase.co/functions/v1/triad-background',
    headers:=jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'SERVICE_ROLE_KEY' LIMIT 1)
    ),
    body:='{}'::jsonb
  );
  $CRON$
);


-- =============================================================================
-- 2. reset-stuck — städar processing_queue var 15:e min. Tre UPDATE i
--    en transaktion:
--
--      sats 1: processing → pending om 6 min utan uppdatering
--              (worker crashad / stuck)
--      sats 2: pending → failed när attempts>=5 (gav upp)
--              [DETTA var buggen: sattes till 'done' → check-violation
--               → hela jobbet rullades tillbaka]
--      sats 3: * → done när sci_done=true AND triad_done=true
--              (uppfyller status_done_requires_both_flags — orörd)
--
--    Rör inte sats 3. Constraintet från 20260715160000 tillåter 'done'
--    exakt när båda flaggor är true, vilket den här satsen kräver.
-- =============================================================================

select cron.schedule(
  'reset-stuck',
  '*/15 * * * *',
  $CRON$
  UPDATE processing_queue SET status='pending'
   WHERE status='processing' AND updated_at < now() - interval '6 minutes';
  UPDATE processing_queue SET status='failed'
   WHERE attempts>=5 AND status='pending';
  UPDATE processing_queue SET status='done'
   WHERE sci_done=true AND triad_done=true AND status!='done';
  $CRON$
);


-- =============================================================================
-- Verifiering (efter apply — redan kört 2026-07-25):
--
--   -- 1. Båda jobben aktiva? OBS: bindestreck i reset-stuck.
--   select jobid, jobname, schedule, active
--     from cron.job
--    where jobname in ('triad_background_30m', 'reset-stuck');
--   -- expected: 2 rader, active = true
--
--   -- 2. Ingen ny run_details med status='failed' de senaste 2h?
--   select j.jobname, d.status, count(*), max(d.start_time) as latest
--     from cron.job_run_details d
--     join cron.job j on j.jobid = d.jobid
--    where j.jobname in ('triad_background_30m', 'reset-stuck')
--      and d.start_time > now() - interval '2 hours'
--    group by j.jobname, d.status;
--   -- expected: enbart status='succeeded'
--
--   -- 3. Historisk kontext (för post-mortem):
--   select j.jobname, count(*) as fails,
--          min(d.start_time) as first_fail, max(d.start_time) as last_fail
--     from cron.job_run_details d
--     join cron.job j on j.jobid = d.jobid
--    where j.jobname in ('triad_background_30m', 'reset-stuck')
--      and d.status = 'failed'
--    group by j.jobname;
--   -- 2026-07-25 pre-fix: triad_background_30m = 97, reset-stuck = 288
-- =============================================================================
