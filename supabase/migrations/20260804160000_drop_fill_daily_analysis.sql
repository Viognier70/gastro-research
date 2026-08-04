-- =============================================================================
-- Rollback av fill-daily-analysis — infört + tagits bort samma dag
-- (2026-08-04). Läs innan du bygger något liknande igen.
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN.
--
-- BAKGRUND:
--
--   20260804150000 skapade fill-daily-analysis edge-fn + tre stödfunktioner
--   (next_analysis_batch, count_analysis_queue, trigger_fill_daily_analysis)
--   + pg_cron 'fill_daily_analysis_5min'. Motiveringen: daily-fetch:s inline
--   analyzeWithClaude-anrop var största kostnaden per artikel och orsakade
--   150 s IDLE_TIMEOUT vid burstar. Att flytta analysen till en egen cron
--   löste timeout-problemet — men det steget var värdefullt oavsett vad som
--   sedan skulle göra analysen.
--
-- VARFÖR ROLLBACK:
--
--   count_analysis_queue() rapporterade 30 518 obetalt-analyserade artiklar
--   direkt efter deploy. Fördelning verifierat 2026-08-04:
--
--     Har core_claim + äldre än 30 dagar:      30 088   (98.6 %)
--     Har core_claim + senaste 30 dagar:          266
--     Saknar core_claim + senaste 30 dagar:        99
--     Saknar core_claim + äldre än 30 dagar:       16
--                                              --------
--                                              30 518
--
--   98,7 % av populationen har redan core_claim (satt av pipeline och
--   backfill-haiku-sci). insight-fältet i frontend är fallback:
--     - index.html:2652: `a.core_claim || a.insight || ''` (Feed-kort)
--     - index.html:4119: `article.core_claim || article.insight || ''` (overlay)
--     - index.html:5176: `a.core_claim || a.insight || a.limitation || ''` (digest)
--
--   För 98,7 % av artiklarna är insight sedan länge dead fallback — core_claim
--   dominerar renderingen. De 115 artiklar som SAKNAR core_claim är antingen
--   pipeline-lag (fylls inom timmar av pipeline) eller pipeline-avvisade
--   (blir aldrig Feed-visible; deras insight-fält ses aldrig).
--
--   Övriga fält som fill-daily-analysis fyllde:
--     - study_type: sätts redan av pipeline (pipeline/index.ts:71) OCH
--       backfill-haiku-sci (backfill-haiku-sci/index.ts:166).
--     - application: används inte i frontend alls (grep 2026-08-04).
--     - limitation: conditional badge i frontend, tomt = ingen badge.
--     - limit_type: samma pattern som limitation.
--
--   Sammantaget: fill-daily-analysis racear pipeline om samma 115 rader och
--   fyller fält som ingen läser. Kostar Sonnet-anrop, kräver egen cron att
--   övervaka, permanent röd flagga i queue_remaining-räknaren tills fylld.
--
-- LÄRDOM FÖR NÄSTA GÅNG:
--
--   Innan man bygger en "asynkron fyllnads-fn" för ett fält — läs frontend
--   för att verifiera att fältet FAKTISKT konsumeras och inte är fallback
--   till ett annat fält som en annan pipeline redan fyller. Grep-check:
--     grep -nE "\.<fält>" index.html
--   Om alla träffar är `foo || <fältet> || ...` → fältet är fallback och
--   sannolikt redundant.
--
--   daily-fetch:s borttagning av analyzeWithClaude BEHÅLLS — den fixade
--   150 s-timeouten och rollback av den vore att återintroducera problemet.
--   Nya artiklar landar bara med insight/application/limitation/limit_type/
--   study_type = '' tills pipeline hinner sätta core_claim (vilket är det
--   Feed använder).
-- =============================================================================


-- Unschedule cronen (idempotent — no-op om jobbet redan är borttaget).
select cron.unschedule('fill_daily_analysis_5min')
 where exists (select 1 from cron.job where jobname = 'fill_daily_analysis_5min');


-- Droppa RPC:erna + trigger-fn:en från 20260804150000.
drop function if exists public.trigger_fill_daily_analysis();
drop function if exists public.count_analysis_queue();
drop function if exists public.next_analysis_batch(int);


-- =============================================================================
-- Verifiering (efter apply):
--
--   -- 1. Cronen borta?
--   select jobid, jobname from cron.job where jobname = 'fill_daily_analysis_5min';
--   -- expected: 0 rader
--
--   -- 2. RPC:erna borta?
--   select proname from pg_proc
--    where proname in ('trigger_fill_daily_analysis',
--                      'count_analysis_queue',
--                      'next_analysis_batch');
--   -- expected: 0 rader
--
--   -- 3. daily-fetch fortsätter fungera utan analyzeWithClaude:
--   select id, created, status_code, left(content::text, 300) as body_preview
--     from net._http_response
--    where created > now() - interval '1 hour'
--    order by created desc limit 5;
--   -- expected: 200-status med added-count > 0 om nya artiklar finns i källorna
-- =============================================================================
