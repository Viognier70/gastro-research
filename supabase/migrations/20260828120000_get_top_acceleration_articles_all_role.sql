-- =============================================================================
-- ORDER 180 (2026-08-28) — get_top_acceleration_articles: 'all'-läge via argmax
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN.
--
-- BAKGRUND:
--
--   Efter ORDER 179 lades Gaining momentum-panelen i Feed-sidopanelen.
--   Frontend hade guard `if(!role || role === 'all') show placeholder`
--   eftersom RPC:n saknade 'all'-stöd — CASE-uttrycken i CTE:n hade ingen
--   ELSE, så filter_role=null gav NULL för alla role-kolumner → episteme
--   is not null-gaten failade → 0 rader.
--
--   User-observation ORDER 180: "Gör momentum konsekvent — argmax över
--   roller när filter_role är null". Trions två andra paneler (Most cited
--   klassisk, Most cited this year) förväntas fungera i 'all'-läget också.
--
-- FIX:
--
--   När filter_role IS NULL:
--     - relevance = GREATEST(alla fem role-relevance-kolumner, 0)
--     - TRIAD-availability-gate = ANY role har episteme is not null
--     - episteme/techne/phronesis SELECT-list = NULL (panelen renderar
--       inte dessa i 'all'-läget; de är oanvända)
--
--   När filter_role är konkret science-slug: oförändrat beteende.
--
--   Argmax-strategin: en artikel kvalificerar för 'all'-listan om NÅGON
--   roll ger den relevance >= min_relevance. Rankningen använder högsta
--   relevance-score över alla roller som sekundär sort (primär är fortfarande
--   acceleration DESC). Detta motsvarar "visa den mest accelererande
--   artikeln som är starkt relevant för åtminstone en profession".
--
-- SIGNATUR: identisk med v1 (20260827130000) → CREATE OR REPLACE ersätter
--   rent, grants preserverade.
--
-- RELATERADE FIX (samma ORDER-batch): get_top_cited_this_year har samma
--   'all'-läges-brist (deployad i 20260827150000). Fixas i separat migration
--   20260828130000 med samma mönster.
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
      -- ORDER 180: TRIAD-fields — NULL i 'all'-läget (panelen använder inte
      -- dem där). Concrete role: kör CASE som vanligt.
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
      -- ORDER 180: relevance — GREATEST över alla roller i 'all'-läget.
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
      -- ORDER 180: TRIAD-availability — ANY role i 'all'-läget, konkret annars.
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
      -- ORDER 180: relevance-gate — GREATEST i 'all'-läget, konkret annars.
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
         s.citation_count::integer  as citation_count,
         s.accel                    as acceleration,
         s.prev_ct::integer         as prev_year_count,
         s.cur_ct::integer          as cur_year_count,
         s.episteme, s.techne, s.phronesis,
         s.relevance::integer       as relevance
    from scored s
   where s.accel is not null
     and s.accel > 1
     and s.prev_ct >= min_prev
   order by s.accel desc, s.relevance desc
   limit limit_n;
end
$function$;


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. 'all'-läget returnerar nu rader:
--   select count(*) from public.get_top_acceleration_articles(null);
--   -- expected: 5 (matchar limit_n default)
--
--   -- 2. TRIAD-fields är NULL i 'all', satta för konkret roll:
--   select filter_role, count(*) filter (where episteme is null) as triad_null,
--          count(*) as total_n
--   from (
--     select 'null'::text as filter_role, episteme
--       from public.get_top_acceleration_articles(null)
--     union all
--     select 'sensory_pro', episteme
--       from public.get_top_acceleration_articles('sensory_pro')
--   ) t group by filter_role;
--   -- expected: null → triad_null = total; sensory_pro → triad_null = 0
--
--   -- 3. Concrete-roll oförändrat beteende:
--   select count(*) = 5 from public.get_top_acceleration_articles('sensory_pro');
--   -- expected: t
-- =============================================================================
