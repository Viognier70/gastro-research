-- =============================================================================
-- next_analysis_batch() + count_analysis_queue() RPC + trigger + pg_cron
-- för fill-daily-analysis edge-fn (2026-08-04).
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- BAKGRUND:
--
--   analyzeWithClaude (Sonnet 4.5, insight/application/limitation/limit_type/
--   study_type) låg tidigare inne i daily-fetch:s saveArticle-loop (1-2 s
--   per artikel). När många artiklar var nya klev daily-fetch:s wallclock
--   över Supabase-gatewayens 150 s IDLE_TIMEOUT och skrivningarna kapades
--   halvvägs. Sex tysta fel före upptäckt 2026-08-04.
--
--   Lösning: flytta analysen till egen edge-fn (fill-daily-analysis) med
--   egen cron. Samma pattern som relevance-check, backfill-haiku-sci,
--   triad-background — läser artiklar utan analys, fyller asynkront.
--
--   Feed-visning bryter INTE av denna delning: index.html:2960 gatekeepar
--   Feed på has_episteme_* OR has_sci_* (från pipeline). Nya artiklar syns
--   inte i Feed förrän pipeline kört och satt core_claim. Insight är en
--   legacy-fallback (index.html:2652, 4119, 5176) som är dominerad av
--   core_claim i alla nuvarande renderingar.
--
-- ORDNING:
--   1. next_analysis_batch(p_limit)  — hämta rader att analysera
--   2. count_analysis_queue()        — HEAD-count för queue_remaining
--   3. trigger_fill_daily_analysis() — vault-baserad service-role-anropare
--   4. cron.schedule '*/5 * * * *'   — kör var femte minut
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. next_analysis_batch(p_limit)
-- ---------------------------------------------------------------------------
-- Kandidat = artikel som saknar insight OCH har tillräckligt lång abstract
-- OCH inte är markerad irrelevant. ORDER BY fetched_at DESC — färskaste
-- först så nyinserterade artiklar plockas upp inom minuter av inhämtning.
--
-- service_role-only. Ingen SECURITY DEFINER — service_role har direct
-- SELECT på articles, INVOKER räcker. Om denna RPC någonsin ska anropas
-- från anon (osannolikt, den innehåller full abstract), lägg till
-- SECURITY DEFINER + search_path — se feedback_rpc_security_definer_for_
-- anon-minnet.

create or replace function public.next_analysis_batch(p_limit int)
returns table(id uuid, title text, abstract text, topic text)
language sql
stable
as $function$
  select id, title, abstract, topic
    from public.articles
   where (insight is null or insight = '')
     and abstract is not null
     and char_length(abstract) > 50
     and irrelevant is not true
   order by fetched_at desc nulls last
   limit p_limit
$function$;

revoke all on function public.next_analysis_batch(int) from public, anon, authenticated;
grant execute on function public.next_analysis_batch(int) to service_role;


-- ---------------------------------------------------------------------------
-- 2. count_analysis_queue()
-- ---------------------------------------------------------------------------
-- Same predicate som next_analysis_batch — används i fill-daily-analysis
-- svaret för att exponera "hur många är kvar". PostgREST kan inte köra
-- char_length-filter direkt så vi wraps count()-frågan i en RPC för
-- konsistens (samma anmodning som noteringen i relevance-check om
-- count_relevance_queue).

create or replace function public.count_analysis_queue()
returns int
language sql
stable
as $function$
  select count(*)::int
    from public.articles
   where (insight is null or insight = '')
     and abstract is not null
     and char_length(abstract) > 50
     and irrelevant is not true
$function$;

revoke all on function public.count_analysis_queue() from public, anon, authenticated;
grant execute on function public.count_analysis_queue() to service_role;


-- ---------------------------------------------------------------------------
-- 3. trigger_fill_daily_analysis() — vault-baserad service-role-anropare
-- ---------------------------------------------------------------------------
-- Samma mönster som trigger_daily_fetch i 20260707100000. raise exception
-- om vault-secret saknas → cron.job_run_details visar tydligt fel snarare
-- än tyst enqueue av trasig request. NOTA: prod-versionen av trigger_
-- daily_fetch skrevs över till hårdkodad anon-nyckel efter migrationen
-- (root cause i two-day-stillestånd 2026-08-02 → 2026-08-04). Följ inte
-- den vägen här — vault-based only.

create or replace function public.trigger_fill_daily_analysis()
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
    raise exception 'trigger_fill_daily_analysis: SERVICE_ROLE_KEY not found in vault.decrypted_secrets';
  end if;

  select net.http_post(
    url     := 'https://igmkzhdovyhbfgjomrsc.supabase.co/functions/v1/fill-daily-analysis',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'Authorization', 'Bearer ' || v_service_key,
                 'apikey',        v_service_key
               ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 300000
  )
  into v_request_id;

  raise notice 'trigger_fill_daily_analysis: enqueued net.http_post request_id=%', v_request_id;
end;
$$;

revoke all on function public.trigger_fill_daily_analysis() from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- 4. pg_cron — kör */5 min. Idempotent: samma jobname ersätter.
-- ---------------------------------------------------------------------------
-- Motivering till */5:
--   - MAX_ANALYSIS_PER_RUN = 60 → ~120 s wallclock per körning → gott om
--     margin mot 150 s gateway.
--   - 60 × (12 tick/h × 24 h) = 17 280 analyser/dygn — mycket mer än
--     daily-fetch-throughputen (~50-500 nya artiklar/dygn i steady state).
--     Initial drain av backlog: se count_analysis_queue()-verifieringen
--     nedan för dagsläget.
--   - */5 undviker överlapp även om Anthropic är trög (funktionen kan ta
--     upp till 5 min utan att kolla sig själv).
select cron.schedule(
  'fill_daily_analysis_5min',
  '*/5 * * * *',
  $CRON$select public.trigger_fill_daily_analysis();$CRON$
);


-- =============================================================================
-- Verifiering (kör efter apply):
--
--   -- 1. Nuvarande backlog?
--   select public.count_analysis_queue();
--   -- expected: 0-några tusen. Om >5 000 är daily-fetch:s analys-borttagning
--   -- redan deploy:d och en initial drain pågår.
--
--   -- 2. RPC returnerar rätt fält?
--   select * from public.next_analysis_batch(3);
--   -- expected: 3 rader (id, title, abstract, topic), färskaste först
--
--   -- 3. Trigger + cron?
--   select jobid, jobname, schedule, active
--     from cron.job where jobname = 'fill_daily_analysis_5min';
--   -- expected: 1 rad, active = true, schedule = '*/5 * * * *'
--
--   -- 4. Manuellt smoke-test (bypass cron):
--   select public.trigger_fill_daily_analysis();
--   -- vänta ~2 min, sen:
--   select id, created, status_code, left(content::text, 400) as body_preview
--     from net._http_response
--    order by created desc limit 3;
--   -- expected: status_code=200, body innehåller ok:true, analyzed:N,
--   -- queue_remaining:M, duration_ms<130000
--
--   -- 5. Grants:
--   select has_function_privilege('anon',
--     'public.trigger_fill_daily_analysis()', 'EXECUTE');   -- false
--   select has_function_privilege('service_role',
--     'public.next_analysis_batch(int)', 'EXECUTE');        -- true
-- =============================================================================
