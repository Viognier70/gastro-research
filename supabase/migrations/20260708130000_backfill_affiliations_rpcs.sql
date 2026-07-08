-- =====================================================================
-- backfill-affiliations edge fn RPCs
-- =====================================================================
-- Two SECURITY DEFINER functions:
--
--   backfill_affiliations_update(...)      per-row: attempted_at + COALESCE
--                                          data merge in ONE statement
--   backfill_affiliations_progress_add(...) counter increment
--
-- Anders's constraints (2026-07-08):
--   - attempted_at and data go in the SAME UPDATE. Two statements where
--     the second can fail = article gets re-fetched next tick.
--   - COALESCE on every data column so re-runs never overwrite existing
--     values (e.g. institutions Scopus already populated).
--
-- Both fns are called by the edge fn using service_role via supabase-js
-- rpc(). SECURITY DEFINER so the fn body runs with owner privileges (no
-- RLS on articles-writes anyway, but explicit is clearer).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Per-row: sets attempted_at unconditionally; COALESCE-merges data cols.
-- Passing all data args as NULL = "attempted, no data" (missed).
-- Passing populated data args = "attempted, data merged where cols were
-- still null". Existing non-null cols are preserved.
-- ---------------------------------------------------------------------
create or replace function public.backfill_affiliations_update(
  p_id                  uuid,
  p_institutions        text[]  default null,
  p_institution_coords  jsonb   default null,
  p_affiliations        text[]  default null,
  p_primary_institution text    default null,
  p_country             text    default null,
  p_countries           text[]  default null
) returns void
language sql
security definer
set search_path = public
as $$
  update public.articles set
    affiliation_attempted_at = now(),
    institutions        = coalesce(institutions,        p_institutions),
    institution_coords  = coalesce(institution_coords,  p_institution_coords),
    affiliations        = coalesce(affiliations,        p_affiliations),
    primary_institution = coalesce(primary_institution, p_primary_institution),
    country             = coalesce(country,             p_country),
    countries           = coalesce(countries,           p_countries)
  where id = p_id;
$$;

grant execute on function public.backfill_affiliations_update(
  uuid, text[], jsonb, text[], text, text, text[]
) to service_role;

-- ---------------------------------------------------------------------
-- Counter increment on the single-row progress table. Atomic in one
-- statement so parallel invocations (should there ever be) can't
-- overwrite each other's counters.
-- ---------------------------------------------------------------------
create or replace function public.backfill_affiliations_progress_add(
  p_updated int,
  p_missed  int
) returns void
language sql
security definer
set search_path = public
as $$
  update public.backfill_affiliations_progress set
    total_updated   = total_updated   + p_updated,
    total_missed    = total_missed    + p_missed,
    total_processed = total_processed + p_updated + p_missed,
    last_run        = now()
  where id = 1;
$$;

grant execute on function public.backfill_affiliations_progress_add(int, int)
  to service_role;

-- =====================================================================
-- Verification (run after apply):
--
--   select proname, pronargs from pg_proc
--    where pronamespace = 'public'::regnamespace
--      and proname like 'backfill_affiliations_%';
--   -- expected: 2 rows (update, progress_add)
--
--   select has_function_privilege('service_role',
--     'public.backfill_affiliations_update(uuid,text[],jsonb,text[],text,text,text[])',
--     'EXECUTE');
--   -- expected: t
-- =====================================================================
