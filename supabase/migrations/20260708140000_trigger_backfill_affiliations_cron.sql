-- =====================================================================
-- trigger_backfill_affiliations() + pg_cron every-minute schedule
-- =====================================================================
-- Same vault-based pattern as trigger_daily_fetch (see migration
-- 20260707100000_trigger_daily_fetch_vault.sql): reads SERVICE_ROLE_KEY
-- from vault.decrypted_secrets on every invocation and posts to the
-- edge fn's URL. If the secret is missing, raises loudly so
-- cron.job_run_details shows the reason instead of a silent 401.
--
-- Schedule: '* * * * *' = every minute. Batch size in the edge fn is
-- 100 articles/tick, ~34s per batch verified manually. 257 639 rows
-- pending → ~2,576 batches → ~43h wall-clock at 60s cadence.
--
-- To pause without unscheduling:
--   update cron.job set active = false where jobname = 'backfill_affiliations_1min';
-- To disable entirely:
--   select cron.unschedule('backfill_affiliations_1min');
-- =====================================================================

create or replace function public.trigger_backfill_affiliations()
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
    raise exception 'trigger_backfill_affiliations: SERVICE_ROLE_KEY not found in vault.decrypted_secrets';
  end if;

  select net.http_post(
    url     := 'https://igmkzhdovyhbfgjomrsc.supabase.co/functions/v1/backfill-affiliations',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'Authorization', 'Bearer ' || v_service_key,
                 'apikey',        v_service_key
               ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 300000
  )
  into v_request_id;

  raise notice 'trigger_backfill_affiliations: enqueued net.http_post request_id=%', v_request_id;
end;
$$;

revoke all on function public.trigger_backfill_affiliations() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- pg_cron: run every minute. Idempotent — same jobname replaces the
-- schedule if this migration is re-applied.
-- ---------------------------------------------------------------------
select cron.schedule(
  'backfill_affiliations_1min',
  '* * * * *',
  $CRON$select public.trigger_backfill_affiliations();$CRON$
);

-- =====================================================================
-- Verification (run after apply):
--
--   -- 1. Job registered?
--   select jobid, jobname, schedule, command, active
--     from cron.job
--    where jobname = 'backfill_affiliations_1min';
--   -- expected: 1 row, active = true
--
--   -- 2. Manual smoke test (bypass cron, get back an http request_id)
--   select public.trigger_backfill_affiliations();
--   -- then wait ~40s and check the reply landed:
--   select id, created, status_code, left(content::text, 200) as body
--     from net._http_response
--    order by created desc limit 3;
--   -- expected: status_code=200, body includes updated:<n>, missed:<n>.
--
--   -- 3. Watch progress live
--   select total_processed, total_updated, total_missed, last_run
--     from public.backfill_affiliations_progress;
--
--   -- 4. Cron job history (after a few minutes)
--   select status, return_message, start_time, end_time
--     from cron.job_run_details
--    where jobid = (select jobid from cron.job
--                    where jobname = 'backfill_affiliations_1min')
--    order by start_time desc limit 10;
--   -- expected: succeeded rows every minute
-- =====================================================================
