-- =============================================================================
-- ORDER 180 (2026-08-28) — get_top_cited_this_year: DEFAULT NULL på
-- filter_role (systerfix till 20260828140000)
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN.
--
-- BAKGRUND: Samma problem som acceleration-RPC:n — signaturen har
-- filter_role UTAN DEFAULT, PostgREST kan inte matcha anrop där body
-- utelämnar parametern → 404 från frontend i 'all'-läget.
--
-- Body oförändrad från 20260828130000. Enda ändring: `filter_role text
-- default null` på rad 43. Full body-duplikat nödvändig (Postgres saknar
-- ALTER FUNCTION ... SET DEFAULT-syntax; default-ändring kräver hela
-- CREATE OR REPLACE FUNCTION).
--
-- Signaturidentity oförändrad (defaults inte del av identity) → REPLACE
-- utan overload-konflikt, grants preserverade.
-- =============================================================================


create or replace function public.get_top_cited_this_year(
  filter_role   text default null,
  min_relevance integer default 6,
  min_cur       integer default 3,
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
  cur_year_count   integer,
  prev_year_count  integer,
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
  scored as (
    select c.*,
      coalesce((select (e->>'cited_by_count')::int
                  from jsonb_array_elements(c.citations_by_year) e
                 where (e->>'year')::int = cur_year limit 1), 0) as cur_ct,
      coalesce((select (e->>'cited_by_count')::int
                  from jsonb_array_elements(c.citations_by_year) e
                 where (e->>'year')::int = cur_year - 1 limit 1), 0) as prev_ct
    from candidates c
  )
  select s.id, s.title, s.headline_en, s.journal, s.year, s.url,
         s.core_claim, s.topic,
         s.citation_count::integer  as citation_count,
         s.cur_ct::integer          as cur_year_count,
         s.prev_ct::integer         as prev_year_count,
         s.episteme, s.techne, s.phronesis,
         s.relevance::integer       as relevance
    from scored s
   where s.cur_ct >= min_cur
   order by s.cur_ct desc, s.relevance desc
   limit limit_n;
end
$function$;


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   select pg_get_function_arguments(oid) from pg_proc
--    where proname='get_top_cited_this_year'
--      and pronamespace='public'::regnamespace;
--   -- expected: "filter_role text DEFAULT NULL::text, min_relevance integer
--   --            DEFAULT 6, min_cur integer DEFAULT 3, limit_n integer
--   --            DEFAULT 5"
--
--   select count(*) from public.get_top_cited_this_year();
--   -- expected: 5
-- =============================================================================
