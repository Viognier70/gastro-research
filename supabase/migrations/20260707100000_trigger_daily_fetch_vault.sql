-- =====================================================================
-- trigger_daily_fetch() — read SERVICE_ROLE_KEY from vault, not hardcoded
-- =====================================================================
-- APPLIED MANUALLY IN PROD 2026-07-07.
-- This file is committed AFTER the fact so the repo matches deployed
-- state. Do NOT re-run against a project that already has this version.
--
-- Symptom: daily-fetch pipeline stopped adding articles after
-- 2026-06-30 11:33 UTC — backfill_progress.last_run frozen from that
-- exact minute onward. Diagnosis showed the trigger fn shipped an
-- anon-key JWT in the Authorization header (some versions with a
-- typo'd project ref, 'ignkzhdovyh' vs correct 'igmkzhdovyh'). Either
-- way Supabase's edge gateway rejects the call with 401 before the
-- fn's Deno handler ever runs, so no fetch happens and no error
-- surfaces in edge fn logs.
--
-- Fix: read the real SERVICE_ROLE_KEY from vault.decrypted_secrets
-- (same secret name jobs 62/66 use) on every invocation. If the
-- secret is missing, raise a loud exception so cron.job_run_details
-- shows the exact reason instead of a silent 401.
--
-- SERVICE_ROLE_KEY: uppercase, already in vault (219 chars). No
-- vault.create_secret step needed.
-- =====================================================================

create or replace function public.trigger_daily_fetch()
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
    raise exception 'trigger_daily_fetch: SERVICE_ROLE_KEY not found in vault.decrypted_secrets';
  end if;

  select net.http_post(
    url     := 'https://igmkzhdovyhbfgjomrsc.supabase.co/functions/v1/daily-fetch',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'Authorization', 'Bearer ' || v_service_key,
                 'apikey',        v_service_key
               ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 300000
  )
  into v_request_id;

  raise notice 'trigger_daily_fetch: enqueued net.http_post request_id=%', v_request_id;
end;
$$;

revoke all on function public.trigger_daily_fetch() from public, anon, authenticated;

-- =====================================================================
-- Verification queries (run after apply):
--
--   -- 1. Key length sanity (never echo the key itself)
--   select length(decrypted_secret) as key_length
--     from vault.decrypted_secrets
--    where name = 'SERVICE_ROLE_KEY';
--   -- expected: 219
--
--   -- 2. Grants
--   select has_function_privilege('anon',          'public.trigger_daily_fetch()', 'EXECUTE'); -- false
--   select has_function_privilege('authenticated', 'public.trigger_daily_fetch()', 'EXECUTE'); -- false
--
--   -- 3. Manual smoke test (bypass cron)
--   select public.trigger_daily_fetch();
--   -- wait ~30s, then:
--   select id, created, status_code, content_type,
--          left(content::text, 200) as body_preview
--     from net._http_response
--    order by created desc
--    limit 3;
--   -- expected: status_code=200, body includes ok:true and an added count.
--
--   -- 4. Did daily-fetch actually work?
--   select max(last_run) as last_activity
--     from public.backfill_progress;
--   -- expected: within the last 5 minutes.
-- =====================================================================
