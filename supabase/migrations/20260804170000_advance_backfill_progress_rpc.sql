-- =============================================================================
-- advance_backfill_progress() — kumulativ total_fetched för backfill_progress
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN.
--
-- BAKGRUND:
--
--   daily-fetch:s updateProgress() (index.ts:559-568) skrev
--   `total_fetched: added` — värdet från SENASTE körningen, inte kumulativt
--   sedan jobbet startade. Kolumnen HETER total_fetched men uppträdde som
--   last_run_added.
--
--   Symptom 2026-08-04: alla 6 öppna openalex-backfill-jobb hade
--   total_fetched=0 trots att current_page rört sig i veckor. Läsaren av
--   backfill_progress kunde inte skilja "jobbet har aldrig lagt till något"
--   från "senaste körningen var noll (dups)". Två helt olika tillstånd med
--   samma synliga signal.
--
--   PostgREST:s .upsert({...}, { onConflict }) kan inte referera till
--   existerande kolumnvärde (`total_fetched = existing + added`), så
--   ackumuleringen måste ske server-side via en RPC med en insert…on
--   conflict do update-sats.
--
-- ANROPARE:
--
--   daily-fetch/index.ts:updateProgress byts från direkt-upsert till
--   supabase.rpc('advance_backfill_progress', {...}). Byte i samma commit.
-- =============================================================================

create or replace function public.advance_backfill_progress(
  p_source     text,
  p_identifier text,
  p_year       int,
  p_page       int,
  p_added      int,
  p_completed  boolean
)
returns void
language sql
as $function$
  insert into public.backfill_progress
    (source, identifier, current_year, current_page, total_fetched, completed, last_run)
  values
    (p_source, p_identifier, p_year, p_page, p_added, p_completed, now())
  on conflict (source, identifier) do update set
    current_year  = excluded.current_year,
    current_page  = excluded.current_page,
    total_fetched = coalesce(backfill_progress.total_fetched, 0) + excluded.total_fetched,
    completed     = excluded.completed,
    last_run      = excluded.last_run;
$function$;

revoke all on function public.advance_backfill_progress(text, text, int, int, int, boolean)
  from public, anon, authenticated;
grant execute on function public.advance_backfill_progress(text, text, int, int, int, boolean)
  to service_role;


-- =============================================================================
-- Verifiering (efter apply):
--
--   -- 1. Grants:
--   select has_function_privilege('anon',
--     'public.advance_backfill_progress(text,text,int,int,int,boolean)', 'EXECUTE'); -- false
--   select has_function_privilege('service_role',
--     'public.advance_backfill_progress(text,text,int,int,int,boolean)', 'EXECUTE'); -- true
--
--   -- 2. Smoke-test: kör två gånger mot samma jobb, kolla att total_fetched
--   --    ackumulerar snarare än överskrivs.
--   select public.advance_backfill_progress(
--     'test_source', 'test_identifier', 2020, 0, 5, false);
--   select total_fetched from public.backfill_progress
--    where source='test_source' and identifier='test_identifier';
--   -- expected: 5
--
--   select public.advance_backfill_progress(
--     'test_source', 'test_identifier', 2020, 1, 3, false);
--   select total_fetched from public.backfill_progress
--    where source='test_source' and identifier='test_identifier';
--   -- expected: 8 (5 + 3, INTE 3)
--
--   -- Städa upp testraden:
--   delete from public.backfill_progress
--    where source='test_source' and identifier='test_identifier';
-- =============================================================================
