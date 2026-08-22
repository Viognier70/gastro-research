-- =============================================================================
-- relevance_check_reason kolumn + next_relevance_batch() RPC + cleanup av
-- 2 215 shorts som fastnat i kön sedan 2026-07-12.
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- BAKGRUND:
--
--   relevance-check-cronen körde tomma anrop varje minut sedan 2026-07-12
--   (1 440 no-op-anrop/dygn). Diagnos 2026-08-04:
--
--     - SELECT:en i index.ts saknade ORDER BY och använde partial-indexet
--       idx_relevance_queue (index on id) → Postgres returnerade 400 lägsta
--       id:na i varje anrop.
--     - Alla 400 lägsta id:na råkade vara artiklar med korta abstract
--       (< 100 tecken; 2 188 helt tomma). JS-vakten `if (abstract.length
--       < 100) { skipped++ continue }` skippade dem utan att skriva
--       relevance_checked=true. Samma 400 hämtades nästa minut. Sedan tre
--       veckor.
--     - Kön 5 908: 2 215 shorts (aldrig bedömbara utan backfill av
--       abstract) + 3 693 fullgoda som svalt bakom shorts-blocket.
--
-- ÄNDRINGAR:
--
--   1. Ny kolumn relevance_check_reason text — spårar VARFÖR raden
--      markerats. Värden: 'haiku', '0kw', 'no_abstract'. Låter oss senare
--      skilja på "bedömd som irrelevant av modell" (irrelevant=true,
--      reason='haiku' eller '0kw') och "kunde ej bedömas" (irrelevant=true,
--      reason='no_abstract') i screening_funnel, health-signaler och
--      framtida kvalitetsmätningar. Utan denna kolumn hade cleanup-
--      UPDATE:n nedan tappat den distinktionen permanent.
--
--   2. Cleanup-UPDATE på 2 215 shorts — markerar dem relevance_checked=true,
--      irrelevant=true, reason='no_abstract'. Motivering till irrelevant=true
--      (vs t.ex. null eller separat unjudgeable-flagga):
--        - Downstream-konsumenter (Feed, screening_funnel, sci_ko-räknare)
--          använder `where irrelevant is not true` för att exkludera rader
--          som inte ska visas. Att sätta irrelevant=true håller shorts
--          borta från de vyerna utan att kräva ändring i varje konsument.
--        - Distinktionen "varför" bevaras via relevance_check_reason —
--          separat kolumn med explicit semantik.
--        - Nya shorts fångas inte längre av SELECT:en (RPC-filtret nedan
--          har `char_length(abstract) >= 100`), så cleanup är engångs-
--          operation; nya rader utan abstract väntar på backfill.
--
--   3. Ny RPC next_relevance_batch(p_limit int) — server-side filtrering
--      OCH ordering. Ersätter client-side .from('articles').select(...).
--      limit(). Samma mönster som authors_backfill_candidates och
--      institution_openalex_ids_backfill_candidates: predikatet ägs av
--      RPC:n, inte spritt över SELECT + JS-vakt. Framtida "shorts" (om
--      någon uppstår) filtreras bort server-side och når aldrig JS.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. Ny kolumn
-- ---------------------------------------------------------------------------

alter table public.articles
  add column if not exists relevance_check_reason text;

comment on column public.articles.relevance_check_reason is
  'Varför raden markerats relevance_checked=true. Värden: '
  '"haiku" (Haiku-klassificering), "0kw" (0 keyword-träffar, auto-irrelevant), '
  '"no_abstract" (< 100 tecken, ingen bedömning möjlig). '
  'null före bedömning eller för rader bedömda före kolumnen skapades (2026-08-04).';


-- ---------------------------------------------------------------------------
-- 2. Cleanup av 2 215 shorts
-- ---------------------------------------------------------------------------
-- Förvänta ~2 215 rader vid apply 2026-08-04. Nummerkontrollera FÖRE
-- att köra: uncomment select-raden nedan, run den först, jämför.
--
-- select count(*) from public.articles
--  where relevance_checked = false
--    and abstract is not null
--    and char_length(abstract) < 100;

update public.articles
   set relevance_checked = true,
       irrelevant = true,
       relevance_checked_at = now(),
       relevance_check_reason = 'no_abstract'
 where relevance_checked = false
   and abstract is not null
   and char_length(abstract) < 100;


-- ---------------------------------------------------------------------------
-- 3. next_relevance_batch(p_limit) RPC
-- ---------------------------------------------------------------------------
-- Filtrerar shorts server-side + ORDER BY id (deterministisk, samma
-- pagineringsmönster som andra backfill-RPC:er). Använder samma partial-
-- index idx_relevance_queue eftersom prefixet matchar; char_length-
-- filtret läggs som recheck ovanpå.
--
-- service_role-only (samma som backfill-RPC:erna). Denna RPC returnerar
-- fullständiga artikel-fält som konsumeras av edge-fn:en; anon behöver
-- inte kunna anropa den.

create or replace function public.next_relevance_batch(p_limit int)
returns table(id uuid, title text, abstract text, journal text, insight text)
language sql
stable
as $function$
  select id, title, abstract, journal, insight
    from public.articles
   where relevance_checked = false
     and abstract is not null
     and char_length(abstract) >= 100
   order by id
   limit p_limit
$function$;

revoke all on function public.next_relevance_batch(int) from public, anon, authenticated;
grant execute on function public.next_relevance_batch(int) to service_role;


-- =============================================================================
-- Verifiering (kör efter apply):
--
--   -- 1. Kolumnen finns?
--   select column_name, data_type, is_nullable
--     from information_schema.columns
--    where table_schema='public' and table_name='articles'
--      and column_name='relevance_check_reason';
--   -- expected: 1 rad, text, YES
--
--   -- 2. Cleanup landade?
--   select count(*) from public.articles
--    where relevance_checked = true
--      and relevance_check_reason = 'no_abstract';
--   -- expected: ~2 215 (initial cleanup)
--
--   -- 3. Kön har nu bara fullgoda kvar?
--   select count(*) from public.articles
--    where relevance_checked = false and abstract is not null;
--   -- expected: ~3 693 (fullgoda som svalt shorts sedan 2026-07-12)
--
--   -- 4. RPC:n plockar rätt?
--   select count(*) from public.next_relevance_batch(50000);
--   -- expected: samma ~3 693 som (3) — RPC-filtret matchar SELECT:en i
--   -- edge-fn:en efter refactor
--
--   -- 5. Grants:
--   select has_function_privilege('anon',
--     'public.next_relevance_batch(int)', 'EXECUTE');            -- false
--   select has_function_privilege('service_role',
--     'public.next_relevance_batch(int)', 'EXECUTE');            -- true
-- =============================================================================
