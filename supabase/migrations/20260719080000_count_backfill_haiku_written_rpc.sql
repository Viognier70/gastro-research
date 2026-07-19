-- ============================================================================
-- count_backfill_haiku_written() — direkt räkning av Metod B-markörer.
-- ============================================================================
--
-- Kompletterar get_backfill_haiku_written() (som returnerar RADER, cappade
-- på PostgREST db-max-rows=1000) med en pur count. Används i sweep-scriptets
-- checkpoint-drift-check: jämför scriptets ackumulerade total_upd mot
-- faktiska markörer i DB. Om de divergerar → skrivningar tappas tyst → STOP.
--
-- Renare signal än role_marked-drift (som är beroende av naturligt
-- pipeline-inflöde och stiger linjärt med tiden oavsett sweep-kvalitet).
-- Markör-räknaren påverkas ENDAST av backfill_haiku_write, ingen ANNAN
-- kod skriver den specifika last_error-strängen.
--
-- Läs-only. Security definer + grant execute to anon (samma familj som
-- get_backfill_haiku_written + stats_no_role_null_kw).

create or replace function public.count_backfill_haiku_written()
returns int
language sql
security definer
stable
set search_path = public
as $function$
  select count(*)::int
  from processing_queue
  where last_error = 'backfill_completed_awaiting_ondemand_triad';
$function$;

grant execute on function public.count_backfill_haiku_written() to anon, authenticated;
