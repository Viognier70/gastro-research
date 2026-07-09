-- =====================================================================
-- trigger_health_mail() + pg_cron 07:00 svensk sommartid (05:00 UTC)
-- =====================================================================
-- Samma vault-baserade mönster som trigger_backfill_affiliations
-- (20260708140000) och trigger_backfill_abstracts (20260709130000):
-- läser SERVICE_ROLE_KEY från vault.decrypted_secrets på varje
-- invocation och POSTar till /functions/v1/health-mail. Om secreten
-- saknas raise:as loud så cron.job_run_details visar det istället för
-- en tyst 401.
--
-- Schedule: '0 5 * * *' (varje dag kl 05:00 UTC). Sverige ligger på
-- CEST (UTC+2) mellan slutet av mars och slutet av oktober, alltså
-- 07:00 lokal tid. Under CET-perioden (nov–mar) hamnar mailet på
-- 06:00 lokal tid — acceptabel drift; om det stör bumpar vi till
-- '0 6 * * *' (08:00 CEST / 07:00 CET) och lever med sommarens 08:00
-- eller separata schedules.
--
-- Pausa utan att unschedulea:
--   update cron.job set active = false where jobname = 'health_mail_daily';
-- Slå av helt:
--   select cron.unschedule('health_mail_daily');
-- =====================================================================

create or replace function public.trigger_health_mail()
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_service_key text;
  v_request_id  bigint;
begin
  select decrypted_secret
    into v_service_key
    from vault.decrypted_secrets
   where name = 'SERVICE_ROLE_KEY'
   limit 1;

  if v_service_key is null or v_service_key = '' then
    raise exception 'trigger_health_mail: SERVICE_ROLE_KEY not found in vault.decrypted_secrets';
  end if;

  select net.http_post(
    url     := 'https://igmkzhdovyhbfgjomrsc.supabase.co/functions/v1/health-mail',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'Authorization', 'Bearer ' || v_service_key,
                 'apikey',        v_service_key
               ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 60000
  )
  into v_request_id;

  raise notice 'trigger_health_mail: enqueued net.http_post request_id=%', v_request_id;
end;
$fn$;

revoke all on function public.trigger_health_mail()
  from public, anon, authenticated;

-- Kör 07:00 svensk sommartid (05:00 UTC) varje dag. Idempotent:
-- cron.schedule med samma jobname ersätter existerande schedule om
-- migrationen re-appliceras.
select cron.schedule(
  'health_mail_daily',
  '0 5 * * *',
  $CRON$select public.trigger_health_mail();$CRON$
);

-- =====================================================================
-- Verifiering (efter apply):
--
--   -- 1. Job registrerad?
--   select jobid, jobname, schedule, active
--     from cron.job
--    where jobname = 'health_mail_daily';
--   -- expected: 1 rad, active = true
--
--   -- 2. Manuell smoke test (bypassar cron)
--   select public.trigger_health_mail();
--   -- vänta ~30s, kolla att net._http_response har status 200:
--   select id, created, status_code, left(content::text, 300) as body
--     from net._http_response
--    order by created desc limit 3;
--
--   -- 3. Cron-historik (efter första faktiska tick)
--   select status, return_message, start_time, end_time
--     from cron.job_run_details
--    where jobid = (select jobid from cron.job
--                    where jobname = 'health_mail_daily')
--    order by start_time desc limit 5;
-- =====================================================================
