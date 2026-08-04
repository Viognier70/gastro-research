-- =============================================================================
-- auto_queue_new_article — abstract-guard vid enqueue (patch av prod-fn)
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- BAKGRUND:
--
--   Triggern `queue_new_article` på articles.INSERT (skapad manuellt utanför
--   git, verifierad i prod 2026-08-04 via pg_trigger) anropar
--   auto_queue_new_article() som VILLKORSLÖST enqueuear varje ny artikel:
--
--     INSERT INTO processing_queue (article_id, status, ...) VALUES (...)
--     ON CONFLICT (article_id) DO NOTHING;
--
--   Utan predikat-check. Resultatet: när backfill-abstracts fyller placeholder
--   ('[unavailable]') eller när källor skickar korta abstracts (< 50 tkn), går
--   raden in i pending-kön direkt. claim_pipeline_batch:s predikat exkluderar
--   sedan raderna (length > 50 AND abstract <> '[unavailable]'), och de ligger
--   kvar som ospuvade orphans. 2 200 av 4 047 pipeline-orphans 2026-08-04 hade
--   den orsaken (jfr migration 20260804180000).
--
-- FIX:
--
--   Ersätt kroppen av auto_queue_new_article med samma abstract-predikat som
--   claim_pipeline_batch använder. Rader utan giltigt abstract enqueueas inte
--   alls. När backfill-abstracts senare fyller in ett riktigt abstract kör
--   backfill-fn:en sin egen enqueue-logik (verifiera separat) — annars måste
--   vi lägga en post-fill trigger på UPDATE articles.abstract.
--
-- VARFÖR IRRELEVANT-CHECKEN INTE ÄR MED HÄR:
--
--   relevance-check sätter irrelevant=true EFTER insert, så vid trigger-tid
--   är kolumnen alltid default false. Att lägga `NEW.irrelevant IS TRUE` här
--   skulle inte fånga något — inga irrelevanta artiklar existerar vid insert.
--
--   De 1 847 irrelevanta orphans i 2026-08-04-städningen är rader som blev
--   irrelevanta efter enqueue, av relevance-check senare. Fångas av
--   sweep-satsen i reset-stuck-cronen (migration 20260804180000). Behåll
--   den — enqueue-guarden fångar bara abstract-familjen (~54 % av orphans),
--   sweep-cronen fångar irrelevant-familjen (~46 %).
--
-- SECURITY:
--
--   SECURITY DEFINER + SET search_path — trigger-fn:en behöver INSERT-rätt
--   på processing_queue oavsett vilken roll som gjorde artikel-INSERT:en.
--   daily-fetch använder service_role idag men om någon annan väg
--   (authenticated user, framtida import-jobb) inserterar articles ska
--   enqueue-triggern fortsätta fungera utan att kräva grants på target-
--   tabellen. Samma feedback_rpc_security_definer_for_anon-mönster.
-- =============================================================================

create or replace function public.auto_queue_new_article()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  -- Guard: skippa enqueue för artiklar som ändå kommer exkluderas av
  -- claim_pipeline_batch (migration 20260716120000, rad 68-71). Utan guarden
  -- ackumulerar processing_queue orphans som reset-stuck-cronen får städa
  -- efterhand — bättre att aldrig sätta in dem.
  if new.abstract is null
     or new.abstract = '[unavailable]'
     or length(new.abstract) <= 50 then
    return new;
  end if;

  insert into public.processing_queue
    (article_id, status, priority, sci_done, triad_done, attempts)
  values
    (new.id, 'pending', 10, false, false, 0)
  on conflict (article_id) do nothing;

  return new;
end;
$function$;


-- =============================================================================
-- Verifiering (efter apply):
--
--   -- 1. Function-definitionen uppdaterad?
--   select pg_get_functiondef(oid)
--     from pg_proc where proname = 'auto_queue_new_article';
--   -- expected: kroppen innehåller `if new.abstract is null …`
--
--   -- 2. Trigger fortfarande kopplad?
--   select tgname, pg_get_triggerdef(oid) as def
--     from pg_trigger
--    where tgrelid = 'public.articles'::regclass
--      and tgname = 'queue_new_article';
--   -- expected: 1 rad, AFTER INSERT, calls auto_queue_new_article
--
--   -- 3. Smoke-test: manuell insert utan abstract → INGEN pending-rad.
--   --    (Använd test-doi + normalizeDoi-pattern så url_unique inte trippar
--   --    på existerande rad. Städa efter.)
--   begin;
--   insert into articles (title, url, source, source_label, fetched_at)
--   values ('TEST guard: no abstract', 'https://doi.org/test/enqueue-guard',
--           'test', 'Test', now()) returning id;
--   -- Notera id, kolla att INGEN processing_queue-rad skapades:
--   select count(*) from processing_queue where article_id =
--     (select id from articles where url='https://doi.org/test/enqueue-guard');
--   -- expected: 0
--   rollback;
--
--   -- 4. Smoke-test: insert med giltigt abstract → EN pending-rad.
--   begin;
--   insert into articles (title, url, abstract, source, source_label, fetched_at)
--   values ('TEST guard: valid abstract',
--           'https://doi.org/test/enqueue-guard-2',
--           repeat('This is a valid abstract for gastronomy research. ', 5),
--           'test', 'Test', now()) returning id;
--   select count(*) from processing_queue where article_id =
--     (select id from articles where url='https://doi.org/test/enqueue-guard-2');
--   -- expected: 1
--   rollback;
--
--   -- 5. Långsiktig mätning: reset-stuck sweep-satsen ska nu ha lägre volym
--   --    än den ursprungliga cleanup:en (2 200 rader). Efter ~1 vecka:
--   select count(*) from processing_queue
--    where status='skipped' and last_error like '%short/missing%'
--      and updated_at > now() - interval '7 days';
--   -- expected: nära 0 (enqueue-guarden fångar dem innan de blir orphans)
--
--   select count(*) from processing_queue
--    where status='skipped' and last_error like '%irrelevant%'
--      and updated_at > now() - interval '7 days';
--   -- expected: rimlig volym som speglar hur många relevance-check flippar
--   -- till irrelevant per vecka (dessa fångas INTE av trigger-guarden —
--   -- se header:s rationale)
-- =============================================================================
