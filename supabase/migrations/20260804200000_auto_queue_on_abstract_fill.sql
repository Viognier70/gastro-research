-- =============================================================================
-- auto_queue_on_abstract_fill — UPDATE-trigger som stänger hålet efter
-- INSERT-guarden (kompletterar 20260804190000_auto_queue_new_article_guard)
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- BAKGRUND:
--
--   INSERT-guarden (20260804190000) hindrar artiklar utan giltigt abstract
--   från att enqueueas vid daily-fetch-insert. Rationalen: undvik orphans
--   som claim_pipeline_batch:s predikat ändå exkluderar
--   (length > 50 AND abstract <> '[unavailable]').
--
--   FÖRE guarden var det säkert att låta artiklar utan abstract enqueueas
--   som pending — backfill-abstracts fyllde abstractet, och nästa gång
--   claim_pipeline_batch körde plockade den upp raderna (predikatet
--   kollas vid claim-tid, inte vid insert).
--
--   EFTER guarden köas de aldrig. Backfill-abstracts fyller ett fält som
--   ingenting sedan reagerar på → artikeln blir permanent osynlig.
--
-- FIX (denna migration):
--
--   AFTER UPDATE OF abstract-trigger på articles. När backfill-abstracts
--   (eller vilken annan writer som helst) skriver ett abstract som
--   överlever claim-predikatet, enqueua raden med samma INSERT som
--   INSERT-guarden använder. WHEN-klausulen filtrerar bort no-op-uppdater-
--   ingar och placeholder-skrivningar innan funktionen anropas.
--
-- SÄKERHETSMODEL:
--
--   ON CONFLICT (article_id) DO NOTHING — samma som INSERT-guarden.
--   Undviker att skriva över processing_queue-rader i status='processing'
--   eller 'done' som råkar hamna i en abstract-uppdatering (t.ex. om
--   backfill-abstracts kör en refresh av en redan analyserad rad).
--
--   Rader i status='skipped' med gammalt "short/missing abstract"-fel
--   uppdateras INTE till pending av denna trigger — det är reset-stuck
--   sweep-cronen (20260804180000) som återstartar dem. Behåll ansvars-
--   fördelningen: enqueue-triggrar för framåt-inflödet, sweep-cronen för
--   historisk data.
--
-- SECURITY DEFINER: samma resonemang som INSERT-guarden. backfill-abstracts
-- kör som service_role idag, men vi vill inte binda triggerns fungerande
-- till en specifik roll.
-- =============================================================================

create or replace function public.auto_queue_on_abstract_fill()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  -- Trigger-WHEN har redan filtrerat: abstract har ändrats + nya värdet
  -- passerar claim-predikatet. Här är kroppen minimal.
  insert into public.processing_queue
    (article_id, status, priority, sci_done, triad_done, attempts)
  values
    (new.id, 'pending', 10, false, false, 0)
  on conflict (article_id) do nothing;

  return new;
end;
$function$;


-- Trigger — WHEN-klausulen är kritisk: matchar exakt claim_pipeline_batch:s
-- abstract-predikat (adopt_orphan_rpcs, rad 68-71). Om DE kraven ändras,
-- ändra HÄR också — annars återuppstår hålet.
--
--   old.abstract IS DISTINCT FROM new.abstract   — undvik trigger-storm på
--     UPDATEs som råkar sätta abstract till samma värde (backfill-abstracts
--     race, admin-scripts som SET abstract=abstract, etc)
--   new.abstract IS NOT NULL                     — NULL fångas inte
--   length(new.abstract) > 50                    — kort abstract = ingen
--                                                  meningsfull pipeline-input
--   new.abstract <> '[unavailable]'              — backfill-abstracts skriver
--                                                  denna sentinel när OA/CR
--                                                  saknar abstract; ska INTE
--                                                  köa

drop trigger if exists queue_on_abstract_fill on public.articles;

create trigger queue_on_abstract_fill
  after update of abstract on public.articles
  for each row
  when (old.abstract is distinct from new.abstract
        and new.abstract is not null
        and length(new.abstract) > 50
        and new.abstract <> '[unavailable]')
  execute function public.auto_queue_on_abstract_fill();


-- =============================================================================
-- Verifiering (efter apply):
--
-- === MÄTFRÅGA: hur många artiklar har abstract men saknar queue-rad? ===
--
--   -- Kör för att förstå läget. Rader som matchar är antingen (a) pre-
--   -- trigger-historik eller (b) framåt-fall som denna migrations trigger
--   -- fångar från och med nu.
--   select count(*) as unqueued_with_valid_abstract
--     from public.articles a
--    where a.abstract is not null
--      and length(a.abstract) > 50
--      and a.abstract <> '[unavailable]'
--      and not exists (
--        select 1 from public.processing_queue q where q.article_id = a.id
--      );
--
-- === INGEN ENGÅNGSKÖRNING ==================================================
--
--   Mätningen 2026-08-04 gav 9 437 rader utan processing_queue-rad. Instinktiv
--   åtgärd: engångs-INSERT som köar dem. GÖR INTE DET.
--
--   Verifiering av samma population (2026-08-04):
--     - 9 437 av 9 437 har core_claim ifyllt
--     - 9 421 av 9 437 har TRIAD-analys (has_episteme_*)
--     - fetched_at-fönster: 2026-05-14 → 2026-06-06
--
--   De är alltså REDAN BEARBETADE — genom en tidigare pipeline-väg som
--   existerade före queue_new_article-triggern skapades. Att köa dem nu
--   skulle trigga claim_pipeline_batch → Haiku sci-scoring + Sonnet TRIAD-
--   generering för färdiga artiklar. Betala tusentals dollar för att skriva
--   över befintligt arbete med (förhoppningsvis) identiskt arbete.
--
--   FRAMTIDA POST-QUERY-DIVERGENS: om siffran STIGER från 9 437 månader
--   framöver, är det ett nytt hål (t.ex. någon ny insert-väg utan trigger).
--   Om den STÅR STILL är den historik som ska förbli i fred. Om den SJUNKER
--   är det troligen att någon rensat historiska rader — undersök men rör
--   inte processing_queue.
--
-- === VERIFIERA TRIGGERN ===
--
--   -- 1. Trigger existerar?
--   select tgname, pg_get_triggerdef(oid) as def
--     from pg_trigger
--    where tgrelid = 'public.articles'::regclass
--      and tgname = 'queue_on_abstract_fill';
--   -- expected: 1 rad, AFTER UPDATE OF abstract, calls auto_queue_on_abstract_fill
--
--   -- 2. Smoke-test: insert utan abstract → ingen queue-rad. Sedan UPDATE
--   --    abstract till giltigt värde → EN queue-rad tillkommer.
--   begin;
--   insert into articles (title, url, source, source_label, fetched_at)
--     values ('TEST abstract-fill trigger',
--             'https://doi.org/test/abstract-fill', 'test', 'Test', now())
--     returning id \gset a
--   select count(*) as before from processing_queue where article_id = :'a_id';
--   -- expected: 0 (INSERT-guarden hindrade enqueue)
--   update articles
--      set abstract = repeat('Valid gastronomy research abstract. ', 5)
--    where id = :'a_id';
--   select count(*) as after from processing_queue where article_id = :'a_id';
--   -- expected: 1 (UPDATE-triggern enqueuade)
--   rollback;
--
--   -- 3. No-op-UPDATE ska INTE trigga (samma värde):
--   begin;
--   insert into articles (title, url, abstract, source, source_label, fetched_at)
--     values ('TEST no-op UPDATE',
--             'https://doi.org/test/no-op-update',
--             repeat('Valid abstract. ', 5),
--             'test', 'Test', now())
--     returning id \gset b
--   -- INSERT-guarden enqueuade nu (giltigt abstract från början) → 1 rad
--   select count(*) from processing_queue where article_id = :'b_id';
--   -- expected: 1
--   update articles set abstract = abstract where id = :'b_id';
--   -- WHEN-klausulen: old IS DISTINCT FROM new = false → trigger skippas
--   select count(*) from processing_queue where article_id = :'b_id';
--   -- expected: 1 (samma som förut, ingen dubblett)
--   rollback;
--
--   -- 4. Placeholder-UPDATE ska INTE trigga:
--   begin;
--   insert into articles (title, url, source, source_label, fetched_at)
--     values ('TEST placeholder skip', 'https://doi.org/test/placeholder',
--             'test', 'Test', now()) returning id \gset c
--   update articles set abstract = '[unavailable]' where id = :'c_id';
--   -- WHEN-klausulen: new.abstract <> '[unavailable]' = false → trigger skippas
--   select count(*) from processing_queue where article_id = :'c_id';
--   -- expected: 0
--   rollback;
-- =============================================================================
