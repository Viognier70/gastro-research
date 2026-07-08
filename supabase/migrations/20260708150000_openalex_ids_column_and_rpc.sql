-- =====================================================================
-- institution_openalex_ids: preserve the ID from OpenAlex's authorships
-- =====================================================================
-- Anders 2026-07-08: the ID sits right there in the same authorships
-- payload we already fetch. Throwing it away means the future coord
-- table has to fuzzy-match on names — and names collide ("Christ
-- University", "Université de Maradi" main vs Diffa campus). With the
-- ID we can hit /institutions/{id} for an exact resolve.
--
-- Order-preservation: the edge fn builds institution_openalex_ids as a
-- parallel array to institutions[], deduped by display_name, same index
-- → same institution. That gives us name (human-readable, filters,
-- search) AND id (unambiguous lookup key) without a join table.
--
-- The RPC signature changes so the old function must be dropped first
-- (Postgres CREATE OR REPLACE can't add args). Then re-create with the
-- new arg in the same COALESCE-all-fields pattern.
-- =====================================================================

alter table public.articles
  add column if not exists institution_openalex_ids text[];

-- Drop old signature (7 args, no openalex_ids)
drop function if exists public.backfill_affiliations_update(
  uuid, text[], jsonb, text[], text, text, text[]
);

-- New signature (8 args, openalex_ids inserted after institutions to
-- keep the parallel-array pair adjacent in the parameter list)
create or replace function public.backfill_affiliations_update(
  p_id                        uuid,
  p_institutions              text[]  default null,
  p_institution_openalex_ids  text[]  default null,
  p_institution_coords        jsonb   default null,
  p_affiliations              text[]  default null,
  p_primary_institution       text    default null,
  p_country                   text    default null,
  p_countries                 text[]  default null
) returns void
language sql
security definer
set search_path = public
as $$
  update public.articles set
    affiliation_attempted_at = now(),
    institutions             = coalesce(institutions,             p_institutions),
    institution_openalex_ids = coalesce(institution_openalex_ids, p_institution_openalex_ids),
    institution_coords       = coalesce(institution_coords,       p_institution_coords),
    affiliations             = coalesce(affiliations,             p_affiliations),
    primary_institution      = coalesce(primary_institution,      p_primary_institution),
    country                  = coalesce(country,                  p_country),
    countries                = coalesce(countries,                p_countries)
  where id = p_id;
$$;

grant execute on function public.backfill_affiliations_update(
  uuid, text[], text[], jsonb, text[], text, text, text[]
) to service_role;

notify pgrst, 'reload schema';

-- =====================================================================
-- Verification (run after apply):
--
--   -- 1. Column added
--   select column_name, data_type
--     from information_schema.columns
--    where table_schema='public' and table_name='articles'
--      and column_name='institution_openalex_ids';
--   -- expected: 1 row, ARRAY
--
--   -- 2. New RPC signature (should be the ONLY backfill_affiliations_update)
--   select proname, pronargs from pg_proc
--    where pronamespace='public'::regnamespace
--      and proname='backfill_affiliations_update';
--   -- expected: 1 row, pronargs=8
--
--   -- 3. service_role can execute
--   select has_function_privilege('service_role',
--     'public.backfill_affiliations_update(uuid,text[],text[],jsonb,text[],text,text,text[])',
--     'EXECUTE');
--   -- expected: t
-- =====================================================================
