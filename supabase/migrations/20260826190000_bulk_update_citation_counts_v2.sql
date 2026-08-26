-- =============================================================================
-- ORDER 176 (2026-08-26) — bulk_update_citation_counts v2
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- ÄNDRING vs 20260826130000-versionen:
--
--   1. Ny param p_run_id bigint DEFAULT NULL — kopplar delta-INSERT till
--      citation_updates_runs.id (bulks utan run_id skriver ingen delta,
--      bra för dry-run-tester från terminal).
--
--   2. Ny valfri payload-field "by_year" per rad — OpenAlex counts_by_year
--      snapshot. Skrivs till articles.citations_by_year, preserverar
--      existerande värde om by_year saknas i payload (COALESCE-mönstret).
--
--   3. Delta-INSERT i public.citation_deltas atomiskt med UPDATE. Använder
--      CTE-snapshot av pre-UPDATE citation_count via Postgres statement-
--      level MVCC (alla CTE:er i samma statement läser samma snapshot,
--      oberoende av updated-CTE-en).
--
-- SIGNATURFÄLLA (samma som ORDER 174 get_most_cited): CREATE OR REPLACE
-- REPLACE:ar bara vid EXAKT signatur-match. Ny param → skulle skapa
-- överlagring bredvid gamla → tvetydiga anrop → SQLSTATE 42725. Fix:
-- DROP gamla explicit i samma migration innan CREATE.
--
-- PAYLOAD-FORMAT v2:
--   [
--     {"id": "<uuid>", "c": <int>, "by_year": [...] },       -- ny form
--     {"id": "<uuid>", "c": <int> }                          -- fortsatt OK
--   ]
--
-- CALLERS: bara scripts/backfill-citation-counts.ts. Uppdateras i samma
-- ORDER 176-batch.
--
-- STATEMENT_TIMEOUT: kvar på 60s. Delta-INSERT lägger till en INSERT över
-- de rader som fick nytt värde (typiskt <5000 per anrop), vilket är
-- försumbart mot UPDATE-kostnaden. Ingen ny risk för timeout.
-- =============================================================================


-- Droppa 1-arg-versionen explicit så vi inte får två överlagringar.
drop function if exists public.bulk_update_citation_counts(jsonb);


create or replace function public.bulk_update_citation_counts(
  payload  jsonb,
  p_run_id bigint default null
)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
set statement_timeout = '60s'
as $function$
declare
  updated_n int;
begin
  with src as (
    select (e->>'id')::uuid  as id,
           (e->>'c')::int    as c,
           e->'by_year'      as by_year   -- NULL om fält saknas
      from jsonb_array_elements(payload) e
  ),
  before_snap as (
    -- Pre-UPDATE snapshot. CTE:n ser gamla värden tack vare Postgres
    -- statement-level MVCC — alla CTE:er i samma statement läser samma
    -- snapshot, oberoende av att updated-CTE:n nedan modifierar tabellen.
    select a.id, a.citation_count as old_c
      from public.articles a
      join src s on s.id = a.id
     where a.citation_count is distinct from s.c
  ),
  updated as (
    update public.articles a
       set citation_count    = s.c,
           citations_by_year = coalesce(s.by_year, a.citations_by_year)
      from src s
     where a.id = s.id
       and a.citation_count is distinct from s.c
    returning a.id, s.c as new_c
  ),
  delta_ins as (
    -- Delta-loggen skrivs bara när run_id passas. Terminal-dry-runs utan
    -- run_id (t.ex. ad-hoc rescore) förorenar inte historiken.
    insert into public.citation_deltas (article_id, run_id, old_count, new_count)
    select u.id, p_run_id, b.old_c, u.new_c
      from updated u
      join before_snap b on b.id = u.id
     where p_run_id is not null
    returning 1
  )
  select count(*)::int into updated_n from updated;
  return updated_n;
end
$function$;


revoke all on function public.bulk_update_citation_counts(jsonb, bigint) from public;
grant execute on function public.bulk_update_citation_counts(jsonb, bigint) to service_role;

comment on function public.bulk_update_citation_counts(jsonb, bigint) is
  'ORDER 176 (2026-08-26) v2: batch-UPDATE citation_count + citations_by_year '
  'atomiskt med INSERT till citation_deltas. Payload: [{"id":"<uuid>","c":<int>,'
  '"by_year":[...]?}, ...]. p_run_id kopplar deltas till citation_updates_runs; '
  'NULL run_id skippar delta-INSERT (för dry-runs). Returnerar antal rader som '
  'faktiskt fick nytt värde.';


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Bara EN överlagring kvar:
--   select pg_get_function_identity_arguments(oid)
--     from pg_proc
--    where proname='bulk_update_citation_counts'
--      and pronamespace='public'::regnamespace;
--   -- expected: en rad — "payload jsonb, p_run_id bigint"
--
--   -- 2. Tom payload = 0 skrivningar, 0 deltas:
--   select public.bulk_update_citation_counts('[]'::jsonb, null);
--   -- expected: 0
--   select count(*) from public.citation_deltas where run_id is null;
--   -- expected: 0
--
--   -- 3. Roundtrip med by_year — skapa fake run, byt värde, kontrollera delta:
--   -- (kör bara i staging)
--   -- insert into citation_updates_runs (triggered_by) values ('manual')
--   --   returning id \gset
--   -- with pick as (select id, citation_count from articles
--   --                where citation_count > 0 limit 1)
--   -- select public.bulk_update_citation_counts(
--   --   jsonb_build_array(jsonb_build_object(
--   --     'id', pick.id,
--   --     'c', pick.citation_count + 1,
--   --     'by_year', '[{"year":2025,"cited_by_count":3}]'::jsonb
--   --   )),
--   --   :'run_id'::bigint
--   -- ) from pick;
--   -- select * from citation_deltas where run_id = :'run_id'::bigint;
--   -- select citations_by_year from articles where id = <pick.id>;
--   -- (städa: byt tillbaka + delete run)
--
--   -- 4. Grants:
--   select has_function_privilege('service_role',
--     'public.bulk_update_citation_counts(jsonb, bigint)', 'EXECUTE'); -- true
--   select has_function_privilege('anon',
--     'public.bulk_update_citation_counts(jsonb, bigint)', 'EXECUTE'); -- false
-- =============================================================================
