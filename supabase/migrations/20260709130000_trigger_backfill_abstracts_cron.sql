-- =====================================================================
-- trigger_backfill_abstracts() + pg_cron every-minute schedule
-- =====================================================================
-- Same vault pattern as trigger_backfill_affiliations
-- (20260708140000_trigger_backfill_affiliations_cron.sql): reads
-- SERVICE_ROLE_KEY from vault.decrypted_secrets on every invocation
-- and POSTs to /functions/v1/backfill-abstracts. Raises loudly if the
-- secret is missing so cron.job_run_details surfaces the reason
-- instead of a silent 401.
--
-- Schedule: '* * * * *' (every minute). Batch = 100 rows/tick, verified
-- ~37s per invocation with 71/100 fill rate. 283 907 rows pending after
-- sentinel nullification → ~47h wall-clock at 60s cadence. Anders plans
-- to bump batch to 200/tick after the first hour of observation.
--
-- To pause without unscheduling:
--   update cron.job set active = false where jobname = 'backfill_abstracts_1min';
-- To disable entirely:
--   select cron.unschedule('backfill_abstracts_1min');
-- =====================================================================

create or replace function public.trigger_backfill_abstracts()
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
    raise exception 'trigger_backfill_abstracts: SERVICE_ROLE_KEY not found in vault.decrypted_secrets';
  end if;

  select net.http_post(
    url     := 'https://igmkzhdovyhbfgjomrsc.supabase.co/functions/v1/backfill-abstracts',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'Authorization', 'Bearer ' || v_service_key,
                 'apikey',        v_service_key
               ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 300000
  )
  into v_request_id;

  raise notice 'trigger_backfill_abstracts: enqueued net.http_post request_id=%', v_request_id;
end;
$fn$;

revoke all on function public.trigger_backfill_abstracts()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- pg_cron: run every minute. Idempotent — same jobname replaces the
-- schedule if this migration is re-applied.
-- ---------------------------------------------------------------------
select cron.schedule(
  'backfill_abstracts_1min',
  '* * * * *',
  $CRON$select public.trigger_backfill_abstracts();$CRON$
);

-- =====================================================================
-- Verification (run after apply):
--
--   -- 1. Job registered?
--   select jobid, jobname, schedule, active
--     from cron.job
--    where jobname = 'backfill_abstracts_1min';
--   -- expected: 1 row, active = true
--
--   -- 2. Manual smoke test (bypass cron, get back an http request_id)
--   select public.trigger_backfill_abstracts();
--   -- vänta ~40s, kolla:
--   select id, created, status_code, left(content::text, 200) as body
--     from net._http_response
--    order by created desc limit 3;
--   -- expected: status_code=200, body innehåller filled:<n>, missed:<n>.
--
--   -- 3. Live-progress (räknas via query — ingen progress-tabell)
--   select
--     count(*) filter (where abstract_attempted_at is not null)  as attempted,
--     count(*) filter (where abstract_attempted_at is not null
--                        and abstract is not null)                as filled,
--     count(*) filter (where abstract_attempted_at is not null
--                        and abstract is null)                    as missed,
--     count(*) filter (where abstract is null
--                        and abstract_attempted_at is null
--                        and url ilike '%doi.org%')               as pending
--   from public.articles;
--
--   -- 4. Cron job history (efter några minuter)
--   select status, return_message, start_time, end_time
--     from cron.job_run_details
--    where jobid = (select jobid from cron.job
--                    where jobname = 'backfill_abstracts_1min')
--    order by start_time desc limit 10;
--   -- expected: succeeded rows every minute
-- =====================================================================
