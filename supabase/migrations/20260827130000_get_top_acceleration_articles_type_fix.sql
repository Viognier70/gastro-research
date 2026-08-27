-- =============================================================================
-- ORDER 177 fix (2026-08-27) — get_top_acceleration_articles typ-fix
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN.
--
-- PROBLEM:
--
--   Föregående migration (20260827120000) kastade SQLSTATE 42804 vid CALL:
--   "Returned type numeric does not match expected type integer in column 16".
--
--   Kolumn 16 = relevance. RETURNS TABLE deklarerar den som integer, men
--   SELECT-uttrycket returnerar numeric — sannolikt eftersom en eller flera
--   av a.relevance_sci_<role>-kolumnerna faktiskt är numeric i prod-schemat.
--   (Git-migrationerna ADD:ar inte relevance_sci_-kolumnerna någonstans,
--   så deras faktiska typ är oobservabel från repo — de existerande
--   RPC-RETURNS-deklarationerna som säger `integer` fungerar troligen tack
--   vare implicit coercion från numeric till integer i RETURN-callers som
--   redan har annan typ-kontroll, men här triggas 42804 hårdare.)
--
--   Samma risk finns för de tre andra integer-deklarerade kolumnerna:
--   - col 9  citation_count
--   - col 11 prev_year_count
--   - col 12 cur_year_count
--
-- LÖSNING:
--
--   Casta alla fyra integer-kolumner explicit till ::integer i outer SELECT.
--   ::integer avrundar fraktioner (t.ex. 7.5 → 7); acceptabelt eftersom
--   samtliga fyra uttryck redan är heltalsdiskretiserade uppströms:
--   - citation_count: sätts av bulk_update_citation_counts med (e->>'c')::int
--   - prev_ct / cur_ct: (e->>'cited_by_count')::int, coalesce(int, 0)
--   - relevance: relevance-scoring är 0-10-skala i praktiken
--
--   acceleration förblir numeric (citation_acceleration returnerar numeric,
--   deklarationen matchar redan).
--
-- SIGNATUR: identisk med v1 → CREATE OR REPLACE ersätter rent, inga
--   duplicerade överlagringar (samma lärdom som ORDER 174-fällan). Grants
--   preserveras automatiskt.
-- =============================================================================


create or replace function public.get_top_acceleration_articles(
  filter_role   text,
  min_prev      integer default 20,
  min_relevance integer default 6,
  limit_n       integer default 5
)
returns table(
  id               uuid,
  title            text,
  headline_en      text,
  journal          text,
  year             text,
  url              text,
  core_claim       text,
  topic            text,
  citation_count   integer,
  acceleration     numeric,
  prev_year_count  integer,
  cur_year_count   integer,
  episteme         text,
  techne           text,
  phronesis        text,
  relevance        integer
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  cur_year int := extract(year from current_date)::int;
begin
  return query
  with candidates as materialized (
    select
      a.id, a.title, a.headline_en, a.journal, a.year, a.url,
      a.core_claim, a.topic, a.citation_count, a.citations_by_year,
      case filter_role
        when 'sensory_pro'         then a.episteme_sensory_pro
        when 'culinary_pro'        then a.episteme_culinary_pro
        when 'gastronomy_culture'  then a.episteme_gastronomy_culture
        when 'hospitality_mgmt'    then a.episteme_hospitality_mgmt
        when 'educator_researcher' then a.episteme_educator_researcher
      end as episteme,
      case filter_role
        when 'sensory_pro'         then a.techne_sensory_pro
        when 'culinary_pro'        then a.techne_culinary_pro
        when 'gastronomy_culture'  then a.techne_gastronomy_culture
        when 'hospitality_mgmt'    then a.techne_hospitality_mgmt
        when 'educator_researcher' then a.techne_educator_researcher
      end as techne,
      case filter_role
        when 'sensory_pro'         then a.phronesis_sensory_pro
        when 'culinary_pro'        then a.phronesis_culinary_pro
        when 'gastronomy_culture'  then a.phronesis_gastronomy_culture
        when 'hospitality_mgmt'    then a.phronesis_hospitality_mgmt
        when 'educator_researcher' then a.phronesis_educator_researcher
      end as phronesis,
      coalesce(case filter_role
        when 'sensory_pro'         then a.relevance_sci_sensory_pro
        when 'culinary_pro'        then a.relevance_sci_culinary_pro
        when 'gastronomy_culture'  then a.relevance_sci_gastronomy_culture
        when 'hospitality_mgmt'    then a.relevance_sci_hospitality_mgmt
        when 'educator_researcher' then a.relevance_sci_educator_researcher
      end, 0) as relevance
    from public.articles a
    where a.citations_by_year is not null
      and jsonb_typeof(a.citations_by_year) = 'array'
      and a.irrelevant is not true
      and case filter_role
            when 'sensory_pro'         then a.episteme_sensory_pro
            when 'culinary_pro'        then a.episteme_culinary_pro
            when 'gastronomy_culture'  then a.episteme_gastronomy_culture
            when 'hospitality_mgmt'    then a.episteme_hospitality_mgmt
            when 'educator_researcher' then a.episteme_educator_researcher
          end is not null
      and coalesce(case filter_role
            when 'sensory_pro'         then a.relevance_sci_sensory_pro
            when 'culinary_pro'        then a.relevance_sci_culinary_pro
            when 'gastronomy_culture'  then a.relevance_sci_gastronomy_culture
            when 'hospitality_mgmt'    then a.relevance_sci_hospitality_mgmt
            when 'educator_researcher' then a.relevance_sci_educator_researcher
          end, 0) >= min_relevance
  ),
  scored as (
    select c.*,
      public.citation_acceleration(c.citations_by_year) as accel,
      coalesce((select (e->>'cited_by_count')::int
                  from jsonb_array_elements(c.citations_by_year) e
                 where (e->>'year')::int = cur_year - 1 limit 1), 0) as prev_ct,
      coalesce((select (e->>'cited_by_count')::int
                  from jsonb_array_elements(c.citations_by_year) e
                 where (e->>'year')::int = cur_year limit 1), 0) as cur_ct
    from candidates c
  )
  select s.id, s.title, s.headline_en, s.journal, s.year, s.url,
         s.core_claim, s.topic,
         s.citation_count::integer  as citation_count,     -- ORDER 177 fix: col 9
         s.accel                    as acceleration,       -- numeric (helper-retur)
         s.prev_ct::integer         as prev_year_count,    -- ORDER 177 fix: col 11
         s.cur_ct::integer          as cur_year_count,     -- ORDER 177 fix: col 12
         s.episteme, s.techne, s.phronesis,
         s.relevance::integer       as relevance           -- ORDER 177 fix: col 16 (42804-boven)
    from scored s
   where s.accel is not null
     and s.accel > 1
     and s.prev_ct >= min_prev
   order by s.accel desc, s.relevance desc
   limit limit_n;
end
$function$;


-- Grants + comment behöver inte omkonfigureras — CREATE OR REPLACE preserverar
-- (samma mönster som get_most_cited ORDER 174-fix, bevisat).


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Ingen ny överlagring skapades (signaturen identisk):
--   select count(*), string_agg(pg_get_function_identity_arguments(oid), ' | ')
--     from pg_proc
--    where proname='get_top_acceleration_articles'
--      and pronamespace='public'::regnamespace;
--   -- expected: 1, "filter_role text, min_prev integer, min_relevance integer, limit_n integer"
--
--   -- 2. Smoke-test — inga 42804 kast:
--   select id, citation_count, acceleration, prev_year_count, cur_year_count, relevance
--     from public.get_top_acceleration_articles('sensory_pro') limit 5;
--   -- expected: 5 rader, alla integer-kolumner faktiskt integer i output.
--
--   -- 3. Alla fem roller — samma diagnos som ORDER 177 candidates-fråga
--   -- (bara nu via själva RPC:n, verifierar end-to-end):
--   select role, (select count(*)
--                   from public.get_top_acceleration_articles(role)) as n
--   from unnest(array[
--     'sensory_pro','culinary_pro','gastronomy_culture',
--     'hospitality_mgmt','educator_researcher'
--   ]) as role;
--   -- expected: 5 rader × 5 kandidater per roll (diagnosen visade rikliga
--   -- kandidater; om någon roll ger < 5 är golvet eller relevance-tröskeln
--   -- boven, inte 42804).
-- =============================================================================
