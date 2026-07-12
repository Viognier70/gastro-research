-- =====================================================================
-- trigger_health_alert() + pg_cron var 30:e min
-- =====================================================================
-- Samma vault-baserade pattern som trigger_health_mail (20260710050000)
-- och trigger_backfill_abstracts (20260709130000): läser SERVICE_ROLE_KEY
-- från vault.decrypted_secrets på varje invocation och POSTar till
-- /functions/v1/health-alert. Om secreten saknas -> raise, så
-- cron.job_run_details visar det istället för en tyst 401.
--
-- Schedule: '*/30 * * * *' — kl :00 och :30 varje timme, UTC. SMS-spam-
-- skyddet ligger i edge-fn (alert_log, 24h cooldown per larmtyp), inte i
-- schedulet.
--
-- OBS: applicera FÖRST efter att health-alert är deployad och testad
-- (manuell trigger med sänkta trösklar -> SMS bekräftat -> trösklar
-- återställda). Applicera denna migration LAST.
--
-- Pausa utan att unschedulea:
--   update cron.job set active = false where jobname = 'health_alert_30m';
-- Slå av helt:
--   select cron.unschedule('health_alert_30m');
-- =====================================================================

create or replace function public.trigger_health_alert()
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
    raise exception 'trigger_health_alert: SERVICE_ROLE_KEY not found in vault.decrypted_secrets';
  end if;

  select net.http_post(
    url     := 'https://igmkzhdovyhbfgjomrsc.supabase.co/functions/v1/health-alert',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'Authorization', 'Bearer ' || v_service_key,
                 'apikey',        v_service_key
               ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 60000
  )
  into v_request_id;

  raise notice 'trigger_health_alert: enqueued net.http_post request_id=%', v_request_id;
end;
$fn$;

revoke all on function public.trigger_health_alert()
  from public, anon, authenticated;

-- Kör var 30:e min, UTC. Idempotent: cron.schedule med samma jobname
-- ersätter existerande schedule om migrationen re-appliceras.
select cron.schedule(
  'health_alert_30m',
  '*/30 * * * *',
  $CRON$select public.trigger_health_alert();$CRON$
);

-- =====================================================================
-- Verifiering (efter apply):
--
--   -- 1. Job registrerad?
--   select jobid, jobname, schedule, active
--     from cron.job
--    where jobname = 'health_alert_30m';
--   -- expected: 1 rad, active = true, schedule = '*/30 * * * *'
--
--   -- 2. Manuell smoke test (bypassar cron):
--   select public.trigger_health_alert();
--   select id, created, status_code, left(content::text, 300) as body
--     from net._http_response
--    order by created desc limit 3;
--
--   -- 3. Efter första cron-tick:
--   select status, return_message, start_time, end_time
--     from cron.job_run_details
--    where jobid = (select jobid from cron.job
--                    where jobname = 'health_alert_30m')
--    order by start_time desc limit 5;
-- =====================================================================
