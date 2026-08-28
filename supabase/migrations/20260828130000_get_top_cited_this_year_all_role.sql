-- =============================================================================
-- ORDER 180 (2026-08-28) — get_top_cited_this_year: 'all'-läge via argmax
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN.
--
-- BAKGRUND:
--
--   Systerpanelen till Gaining momentum (get_top_cited_this_year, deployad
--   20260827150000). Har SAMMA 'all'-lägesbrist som acceleration-RPC:n:
--   CASE utan ELSE i CTE:n → filter_role=null ger NULL för alla role-
--   kolumner → episteme is not null-gaten failar → 0 rader.
--
--   Frontend loadCitedThisYear har (som loadMomentum) placeholder-guard
--   som aldrig anropar RPC:n i 'all'-läget. User observerade i ORDER 180
--   att "Most cited this year fungerar utan roll" men frontend-koden visar
--   fortfarande "Pick a profession above". Antingen har user inte testat,
--   eller så förlitar sig på trions gemensamma förväntan om konsekvent
--   beteende.
--
--   Fix same-batch tillsammans med get_top_acceleration_articles (migration
--   20260828120000) — samma pattern, samma verifieringsdisciplin.
--
-- FIX: identisk mönster som acceleration-RPC:n:
--   - filter_role IS NULL → relevance via GREATEST över alla roller
--   - filter_role IS NULL → TRIAD-availability via OR över alla episteme
--   - filter_role IS NULL → TRIAD-fields (episteme/techne/phronesis) NULL
--   - filter_role konkret → oförändrat
--
-- SIGNATUR: identisk med v1 (20260827150000) → CREATE OR REPLACE.
-- =============================================================================


create or replace function public.get_top_cited_this_year(
  filter_role   text,
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
-- VERIFIERING EFTER APPLY (samma disciplin som acceleration-migrationen):
--
--   select count(*) from public.get_top_cited_this_year(null);   -- expected: 5
--   select count(*) = 5 from public.get_top_cited_this_year('sensory_pro'); -- t
-- =============================================================================
