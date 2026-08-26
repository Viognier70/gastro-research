-- =============================================================================
-- ORDER 176 (2026-08-26) — bulk_update_citation_counts v3
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- BAKGRUND:
--
--   v2:s WHERE-klausul gate:ade UPDATE på `citation_count IS DISTINCT FROM s.c`
--   — dvs bara rader där count ändrats fick UPDATE. Problemet efter första
--   full-körning av ORDER 175 (28 750 rader har korrekt count) är att
--   citations_by_year är NULL för hela korpusen, men aldrig skrivs eftersom
--   count redan är rätt. Rows updated: 0 varje körning tills OpenAlex-count
--   ändras nog för att trigga en UPDATE.
--
--   v3 broadening: UPDATE:a också när s.by_year är satt OCH skiljer sig från
--   existerande citations_by_year. Delta-loggen (citation_deltas) fortsätter
--   skrivas BARA för count-ändringar — by_year-only-uppdateringar är
--   snapshot-refresh, inte "artikel-rörelse".
--
-- JSONB-JÄMFÖRELSE ÄR ORDERKÄNSLIG:
--
--   Postgres jsonb-array equality kräver samma element-ordning. OpenAlex
--   returnerar counts_by_year vanligen sorterat på year DESC, men det är
--   inte garanterat. Client-side i backfill-scriptet normaliseras arrayen
--   till year ASC innan send, så server-jämförelsen blir stabil även när
--   OpenAlex råkar leverera i annan ordning.
--
--   Under v3-rollout kommer första körningen skriva om ALLA rader som fick
--   citations_by_year från v2 (som skrev osorterat) — engångskostnad, allt
--   ligger sedan i normaliserad form.
--
-- SIGNATURFÄLLA (samma som v2 → v1 och ORDER 174 get_most_cited):
--   CREATE OR REPLACE kräver EXAKT signatur-match. Vi håller samma signatur
--   som v2 (payload jsonb, p_run_id bigint DEFAULT NULL), så REPLACE räcker
--   — ingen DROP behövs.
-- =============================================================================


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
           e->'by_year'      as by_year
      from jsonb_array_elements(payload) e
  ),
  before_snap as (
    -- v3: filtret här flyttat till delta_ins-CTE:n. Snapshot:en behöver
    -- innehålla ALLA src-rader så vi kan skilja "count-ändring" från
    -- "by_year-only-ändring" i delta-INSERT nedan.
    select a.id, a.citation_count as old_c
      from public.articles a
      join src s on s.id = a.id
  ),
  updated as (
    update public.articles a
       set citation_count    = s.c,
           citations_by_year = coalesce(s.by_year, a.citations_by_year)
      from src s
     where a.id = s.id
       and (
             -- Count-ändring (v2-beteende)
             a.citation_count is distinct from s.c
             -- ELLER: by_year skickad och skiljer sig (v3-nytt). NULL by_year
             -- från client (t.ex. verk utan citeringar) triggar aldrig detta.
          or (s.by_year is not null
              and a.citations_by_year is distinct from s.by_year)
           )
    returning a.id, s.c as new_c
  ),
  delta_ins as (
    -- Delta-loggen är per definition om citation_count. Skriv BARA när count
    -- faktiskt ändrades — by_year-only-uppdateringar är snapshot-refresh,
    -- inte "artikel rörde sig". Utan detta filter skulle citation_deltas få
    -- brusrader med old_count = new_count varje körning där by_year skrivs.
    insert into public.citation_deltas (article_id, run_id, old_count, new_count)
    select u.id, p_run_id, b.old_c, u.new_c
      from updated u
      join before_snap b on b.id = u.id
     where p_run_id is not null
       and b.old_c is distinct from u.new_c
    returning 1
  )
  select count(*)::int into updated_n from updated;
  return updated_n;
end
$function$;


comment on function public.bulk_update_citation_counts(jsonb, bigint) is
  'ORDER 176 (2026-08-26) v3: UPDATE:ar på count-ändring ELLER by_year-ändring '
  '(v2 gate:ade bara på count → citations_by_year skrevs aldrig när count var '
  'stabilt). Delta-INSERT till citation_deltas kvar bara vid count-ändring. '
  'JSONB-jämförelse förutsätter client-side sorterad by_year (year ASC).';


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Signatur oförändrad från v2 (bara en överlagring):
--   select pg_get_function_identity_arguments(oid)
--     from pg_proc
--    where proname='bulk_update_citation_counts'
--      and pronamespace='public'::regnamespace;
--   -- expected: "payload jsonb, p_run_id bigint"
--
--   -- 2. by_year-only write triggar UPDATE utan delta-rad (staging):
--   -- insert into citation_updates_runs (triggered_by) values ('manual')
--   --   returning id \gset run
--   -- with pick as (
--   --   select id, citation_count from articles
--   --    where citation_count > 0 and citations_by_year is null limit 1
--   -- )
--   -- select public.bulk_update_citation_counts(
--   --   jsonb_build_array(jsonb_build_object(
--   --     'id', pick.id,
--   --     'c',  pick.citation_count,       -- OFÖRÄNDRAT
--   --     'by_year', '[{"year":2024,"cited_by_count":3}]'::jsonb
--   --   )),
--   --   :'run'::bigint
--   -- ) from pick;
--   -- expected: 1 (UPDATE räknas)
--   -- select count(*) from citation_deltas where run_id = :'run'::bigint;
--   -- expected: 0 (ingen delta-rad — count oförändrat)
--   -- select citations_by_year from articles where id = <pick.id>;
--   -- expected: [{"year":2024,"cited_by_count":3}]
--
--   -- 3. Count-ändring skriver båda (staging):
--   -- select public.bulk_update_citation_counts(
--   --   jsonb_build_array(jsonb_build_object(
--   --     'id', <pick.id>, 'c', <pick.count>+1
--   --   )), :'run'::bigint
--   -- );
--   -- expected: 1 UPDATE + 1 rad i citation_deltas
--   -- (städa: byt tillbaka count, delete run)
--
--   -- 4. Ingen no-op UPDATE (count OCH by_year oförändrade → 0):
--   -- select public.bulk_update_citation_counts(
--   --   jsonb_build_array(jsonb_build_object(
--   --     'id', <pick.id>, 'c', <pick.count>,
--   --     'by_year', <pick.by_year>
--   --   )), :'run'::bigint
--   -- );
--   -- expected: 0
-- =============================================================================
