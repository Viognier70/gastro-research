-- =============================================================================
-- ORDER 180 (2026-08-28) — get_top_acceleration_articles: filter-före-beräkning
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN.
--
-- BAKGRUND:
--
--   ORDER 180 punkt 3 lade argmax-branch (20260828120000) + DEFAULT NULL
--   (20260828140000). Frontend fungerar men RPC:n timeout:ar med 57014
--   efter ~3s när den kallas med konkret roll. Anon-defaultens
--   statement_timeout är ~3s.
--
--   Rot-orsak (Anders diagnos 2026-08-28): `citation_acceleration` beräknas
--   FÖRE min_prev-filtret. scored-CTE:n kallar helpern på VARJE candidate
--   (28k+ rader med citations_by_year), varav ~90 % sedan filtreras bort
--   av `prev_ct >= min_prev`. Slösad compute + risk för framtida overflow
--   på rader som ändå skulle uteslutas (t.ex. accel=15129 på artikel med
--   prev_ct=1 som min_prev=20 skulle ha filtrerat).
--
-- FIX: omstrukturera CTE-kedjan så filtrering sker före dyr beräkning:
--
--   candidates (materialized) → with_prev (lägger prev_ct)
--                            → qualified (WHERE prev_ct >= min_prev)
--                            → scored (kallar citation_acceleration bara
--                                      på överlevande, plus cur_ct)
--
--   Postgres query-planner kan nu skjuta prev_ct-subselect nära candidates-
--   scan (samma tabell) och skära bort ~90 % av raderna innan den dyra
--   citation_acceleration-anropet. cur_ct-subselecten görs också bara på
--   överlevande rader.
--
-- RETURNS TABLE: acceleration förblir `numeric` utan precision-restriktion
--   (samma som tidigare version — Anders konfirmerade "utan precision").
--   Filter-före-beräkning är den rätta rot-orsaks-fixen; obundet numeric
--   är belt-and-suspenders.
--
-- SIGNATUR: identisk med 20260828140000 (filter_role text default null +
--   tre integer-defaults) → CREATE OR REPLACE ersätter rent.
-- =============================================================================


create or replace function public.get_top_acceleration_articles(
  filter_role   text default null,
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
      case when filter_role is null then null
           else case filter_role
             when 'sensory_pro'         then a.episteme_sensory_pro
             when 'culinary_pro'        then a.episteme_culinary_pro
             when 'gastronomy_culture'  then a.episteme_gastronomy_culture
             when 'hospitality_mgmt'    then a.episteme_hospitality_mgmt
             when 'educator_researcher' then a.episteme_educator_researcher
           end
      end as episteme,
      case when filter_role is null then null
           else case filter_role
             when 'sensory_pro'         then a.techne_sensory_pro
             when 'culinary_pro'        then a.techne_culinary_pro
             when 'gastronomy_culture'  then a.techne_gastronomy_culture
             when 'hospitality_mgmt'    then a.techne_hospitality_mgmt
             when 'educator_researcher' then a.techne_educator_researcher
           end
      end as techne,
      case when filter_role is null then null
           else case filter_role
             when 'sensory_pro'         then a.phronesis_sensory_pro
             when 'culinary_pro'        then a.phronesis_culinary_pro
             when 'gastronomy_culture'  then a.phronesis_gastronomy_culture
             when 'hospitality_mgmt'    then a.phronesis_hospitality_mgmt
             when 'educator_researcher' then a.phronesis_educator_researcher
           end
      end as phronesis,
      case when filter_role is null then
        greatest(
          coalesce(a.relevance_sci_sensory_pro,         0),
          coalesce(a.relevance_sci_culinary_pro,        0),
          coalesce(a.relevance_sci_gastronomy_culture,  0),
          coalesce(a.relevance_sci_hospitality_mgmt,    0),
          coalesce(a.relevance_sci_educator_researcher, 0)
        )
      else
        coalesce(case filter_role
          when 'sensory_pro'         then a.relevance_sci_sensory_pro
          when 'culinary_pro'        then a.relevance_sci_culinary_pro
          when 'gastronomy_culture'  then a.relevance_sci_gastronomy_culture
          when 'hospitality_mgmt'    then a.relevance_sci_hospitality_mgmt
          when 'educator_researcher' then a.relevance_sci_educator_researcher
        end, 0)
      end as relevance
    from public.articles a
    where a.citations_by_year is not null
      and jsonb_typeof(a.citations_by_year) = 'array'
      and a.irrelevant is not true
      and (
        case when filter_role is null then
          (a.episteme_sensory_pro         is not null
           or a.episteme_culinary_pro        is not null
           or a.episteme_gastronomy_culture  is not null
           or a.episteme_hospitality_mgmt    is not null
           or a.episteme_educator_researcher is not null)
        else
          case filter_role
            when 'sensory_pro'         then a.episteme_sensory_pro
            when 'culinary_pro'        then a.episteme_culinary_pro
            when 'gastronomy_culture'  then a.episteme_gastronomy_culture
            when 'hospitality_mgmt'    then a.episteme_hospitality_mgmt
            when 'educator_researcher' then a.episteme_educator_researcher
          end is not null
        end
      )
      and (
        case when filter_role is null then
          greatest(
            coalesce(a.relevance_sci_sensory_pro,         0),
            coalesce(a.relevance_sci_culinary_pro,        0),
            coalesce(a.relevance_sci_gastronomy_culture,  0),
            coalesce(a.relevance_sci_hospitality_mgmt,    0),
            coalesce(a.relevance_sci_educator_researcher, 0)
          )
        else
          coalesce(case filter_role
            when 'sensory_pro'         then a.relevance_sci_sensory_pro
            when 'culinary_pro'        then a.relevance_sci_culinary_pro
            when 'gastronomy_culture'  then a.relevance_sci_gastronomy_culture
            when 'hospitality_mgmt'    then a.relevance_sci_hospitality_mgmt
            when 'educator_researcher' then a.relevance_sci_educator_researcher
          end, 0)
        end
      ) >= min_relevance
  ),
  -- ORDER 180 fix (2026-08-28): filter-före-beräkning.
  -- Steg 1: lägg prev_ct (billig subselect per rad).
  with_prev as (
    select c.*,
      coalesce((select (e->>'cited_by_count')::int
                  from jsonb_array_elements(c.citations_by_year) e
                 where (e->>'year')::int = cur_year - 1 limit 1), 0) as prev_ct
    from candidates c
  ),
  -- Steg 2: filtrera på min_prev INNAN citation_acceleration anropas.
  qualified as (
    select * from with_prev where prev_ct >= min_prev
  ),
  -- Steg 3: beräkna accel + cur_ct bara på överlevande (typiskt ~10 % av
  -- candidates). Undviker slösad compute på rader som ändå faller bort,
  -- plus skyddar mot framtida overflow på rader med små prev_ct som ger
  -- extrema accel-värden.
  scored as (
    select q.*,
      public.citation_acceleration(q.citations_by_year) as accel,
      coalesce((select (e->>'cited_by_count')::int
                  from jsonb_array_elements(q.citations_by_year) e
                 where (e->>'year')::int = cur_year limit 1), 0) as cur_ct
    from qualified q
  )
  select s.id, s.title, s.headline_en, s.journal, s.year, s.url,
         s.core_claim, s.topic,
         s.citation_count::integer  as citation_count,
         s.accel                    as acceleration,
         s.prev_ct::integer         as prev_year_count,
         s.cur_ct::integer          as cur_year_count,
         s.episteme, s.techne, s.phronesis,
         s.relevance::integer       as relevance
    from scored s
   where s.accel is not null
     and s.accel > 1
   order by s.accel desc, s.relevance desc
   limit limit_n;
end
$function$;


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Ingen 57014 vid roll-anrop:
--   select count(*) from public.get_top_acceleration_articles('sensory_pro');
--   -- expected: 5, elapsed <3s
--
--   -- 2. 'all'-läget fortfarande fungerar (argmax-branch orörd):
--   select count(*) from public.get_top_acceleration_articles();
--   -- expected: 5
--
--   -- 3. Signaturen oförändrad:
--   select pg_get_function_arguments(oid) from pg_proc
--    where proname='get_top_acceleration_articles'
--      and pronamespace='public'::regnamespace;
-- =============================================================================
