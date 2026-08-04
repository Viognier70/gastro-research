-- =============================================================================
-- processing_queue cleanup + defensiv sweep-sats i reset-stuck-cronen
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN.
--
-- BAKGRUND:
--
--   pipeline (via claim_pipeline_batch RPC) returnerade 0 rader trots
--   4 047 pending i processing_queue. Diagnos 2026-08-04:
--
--     Kort abstract (length <= 50):  2 200
--     irrelevant = true:             1 847
--                                    --------
--                                    4 047
--
--   Ingen giltig kandidat existerade. Räknaren "remaining: 4047" ljög —
--   det fanns 0 verkliga jobb, resten är historisk soppa som aldrig
--   kommer bearbetas.
--
--   De 1 847 irrelevanta är samma population som relevance-check städade
--   tidigare idag (2 215 no-abstract-rader markerade irrelevant=true).
--   De 2 200 korta är samma familj — abstracts som backfill-abstracts inte
--   fyllt eller som källorna gett som placeholder/kort text.
--
-- KONSTRAINT-CHECK:
--
--   status_done_requires_both_flags (20260715160000) kräver att status='done'
--   → sci_done AND triad_done. Andra värden är fria. 'skipped' passar
--   perfekt: raderna blev aldrig bearbetade, vi ska inte ljuga om done.
--
-- ORDNING:
--
--   1. Engångs-cleanup av nuvarande 4 047 orphans → 'skipped' med
--      last_error som skiljer irrelevant från short-abstract.
--   2. Extend reset-stuck-cronen (20260725140000) med 4:e sats som
--      kontinuerligt sveper samma population. Utan detta ackumulerar
--      kön skräp varje gång relevance-check markerar irrelevant eller
--      daily-fetch laddar in korta abstracts.
--
-- KVARSTÅENDE UTREDNING (utanför denna migration):
--
--   Vem SKRIVER till processing_queue? Ingen INSERT i git — vare sig
--   edge-fn eller migration. Sannolikt en trigger på articles eller en
--   RPC skapad manuellt utanför git. Kör i prod för att hitta:
--
--     select tgname, pg_get_triggerdef(t.oid) from pg_trigger t
--       join pg_class c on c.oid = t.tgrelid
--      where c.relname in ('articles', 'processing_queue');
--
--     select p.proname from pg_proc p
--      where pg_get_functiondef(p.oid) ilike '%insert%into%processing_queue%';
--
--   Idealt patchar vi enqueue-vägen med samma predikat (`irrelevant is not
--   true and length(abstract) > 50 and abstract <> '[unavailable]'`) så
--   skräp aldrig kommer in. Tills dess svarar reset-stuck-svepet för
--   kontinuerlig städning.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. Cleanup av existerande 4 047 orphans
-- ---------------------------------------------------------------------------
-- last_error skiljer de två familjerna så framtida granskningar kan urskilja
-- "obedömbar-utan-abstract" från "flaggad-irrelevant" — samma resonemang som
-- relevance_check_reason på articles-sidan.

update public.processing_queue pq
   set status = 'skipped',
       last_error = case
         when a.irrelevant = true then 'unqueueable: articles.irrelevant=true (marked by relevance-check)'
         else 'unqueueable: articles.abstract length <= 50 (short/missing)'
       end,
       updated_at = now()
  from public.articles a
 where a.id = pq.article_id
   and pq.status = 'pending'
   and (a.irrelevant = true or length(coalesce(a.abstract, '')) <= 50);


-- ---------------------------------------------------------------------------
-- 2. Extend reset-stuck-cronen med 4:e sats (defensiv sweep)
-- ---------------------------------------------------------------------------
-- Cron.schedule med samma jobname ersätter idempotent. De tre gamla
-- satserna oförändrade (samma logik som 20260725140000:104-115).
-- Den nya 4:e satsen speglar predikatet i claim_pipeline_batch — om ett
-- jobb aldrig kan matcha claim, ska det inte ligga kvar som pending.

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
  UPDATE processing_queue pq SET
       status='skipped',
       last_error=CASE
         WHEN a.irrelevant = true THEN 'unqueueable: articles.irrelevant=true'
         ELSE 'unqueueable: articles.abstract length <= 50'
       END,
       updated_at=now()
    FROM articles a
   WHERE a.id = pq.article_id AND pq.status='pending'
     AND (a.irrelevant = true OR length(coalesce(a.abstract, '')) <= 50);
  $CRON$
);


-- =============================================================================
-- Verifiering (efter apply):
--
--   -- 1. Cleanup:
--   select status, count(*) from processing_queue
--    where status in ('pending','skipped','processing','done','failed')
--    group by status order by status;
--   -- expected: pending går från ~4 047 till 0 (om ingen ny data
--   -- kommit in mellan), skipped ökar med samma tal
--
--   -- 2. last_error-fördelning på nya skipped:
--   select last_error, count(*) from processing_queue
--    where status='skipped' and updated_at > now() - interval '1 hour'
--    group by 1;
--   -- expected: två rader (irrelevant + short-abstract), ~4 047 totalt
--
--   -- 3. Nästa pipeline-tick ska returnera remaining=0 istället för 4 047:
--   select public.claim_pipeline_batch(20);
--   -- expected: '[]'::json (inga verkliga jobb kvar)
--
--   -- 4. Cronen fortfarande aktiv med ny sats?
--   select command from cron.job where jobname='reset-stuck';
--   -- expected: fyra UPDATE-satser
--
--   -- 5. Utred vem som skriver till processing_queue (se header):
--   select tgname, pg_get_triggerdef(t.oid) from pg_trigger t
--     join pg_class c on c.oid = t.tgrelid
--    where c.relname in ('articles', 'processing_queue');
-- =============================================================================
