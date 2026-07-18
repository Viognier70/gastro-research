-- ============================================================================
-- get_backfill_haiku_written() — hittar de artiklar som backfill_haiku_write
-- markerat via Metod B:s unika last_error-signatur.
-- ============================================================================
--
-- Returnerar processing_queue-rader med
-- last_error='backfill_completed_awaiting_ondemand_triad'. Det är MARKÖREN
-- som backfill_haiku_write (20260718120000) skriver. Att söka på markören
-- är säkrare än att gissa IDs — visar de FAKTISKT skrivna, inte de vi
-- TROR skrevs.
--
-- Används för STEG 3-verifiering (2026-07-18 mikro-live limit=5):
--   1. Hitta ID-lista → verifiera articles.role_scores + keywords
--   2. Verifiera queue: status='skipped', sci_done=true, triad_done=false
--   3. Efter pipeline-anrop: kolla samma IDs → förblev de 'skipped'?
--
-- Läs-only. Security definer + grant execute to anon (samma familj som
-- stats_no_role_null_kw + sample_no_role_null_kw). Behålls som permanent
-- observability-verktyg för Metod B-övervakning under och efter svepet.

create or replace function public.get_backfill_haiku_written(p_limit int default 100)
returns table (
  article_id uuid,
  status text,
  sci_done boolean,
  triad_done boolean,
  last_error text,
  updated_at timestamptz
)
language sql
security definer
stable
set search_path = public
as $function$
  select
    q.article_id,
    q.status,
    q.sci_done,
    q.triad_done,
    q.last_error,
    q.updated_at
  from processing_queue q
  where q.last_error = 'backfill_completed_awaiting_ondemand_triad'
  order by q.updated_at desc
  limit p_limit;
$function$;

grant execute on function public.get_backfill_haiku_written(int) to anon, authenticated;
