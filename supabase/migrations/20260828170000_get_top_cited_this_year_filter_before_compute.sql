-- =============================================================================
-- ORDER 180 (2026-08-28) — get_top_cited_this_year: filter-före-beräkning
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN.
--
-- BAKGRUND: Systerpanel till Gaining momentum, samma performance-mönster.
-- Filtret min_cur >= 3 sker efter cur_ct-beräkning. Restructure så bara
-- kvalificerande rader plockar prev_ct (som bara används i display).
--
-- FIX: CTE-omstrukturering — kompute cur_ct + relevance i with_cur, sort+
-- limit i top_n för att skära bort icke-kvalificerande rader, sedan compute
-- prev_ct bara på överlevande top-N (typiskt 5 rader). Undviker jsonb-
-- arbete på icke-kvalificerande rader.
--
-- SIGNATUR: identisk med 20260828150000 → CREATE OR REPLACE ersätter rent.
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
  -- ORDER 180 fix (2026-08-28): filter-före-beräkning.
  -- Steg 1: compute cur_ct (behövs för sort + filter).
  with_cur as (
    select c.*,
      coalesce((select (e->>'cited_by_count')::int
                  from jsonb_array_elements(c.citations_by_year) e
                 where (e->>'year')::int = cur_year limit 1), 0) as cur_ct
    from candidates c
  ),
  -- Steg 2: filtrera på min_cur INNAN prev_ct beräknas.
  qualified as (
    select * from with_cur where cur_ct >= min_cur
  ),
  -- Steg 3: sort + limit inuti CTE så prev_ct-computen bara körs på
  -- de rader som faktiskt kommer med i output.
  top_n as (
    select * from qualified order by cur_ct desc, relevance desc limit limit_n
  ),
  -- Steg 4: compute prev_ct bara på topp-N-överlevande.
  scored as (
    select t.*,
      coalesce((select (e->>'cited_by_count')::int
                  from jsonb_array_elements(t.citations_by_year) e
                 where (e->>'year')::int = cur_year - 1 limit 1), 0) as prev_ct
    from top_n t
  )
  select s.id, s.title, s.headline_en, s.journal, s.year, s.url,
         s.core_claim, s.topic,
         s.citation_count::integer  as citation_count,
         s.cur_ct::integer          as cur_year_count,
         s.prev_ct::integer         as prev_year_count,
         s.episteme, s.techne, s.phronesis,
         s.relevance::integer       as relevance
    from scored s
   order by s.cur_ct desc, s.relevance desc;
end
$function$;


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   select count(*) from public.get_top_cited_this_year('sensory_pro');
--   -- expected: 5, elapsed <3s
--
--   select count(*) from public.get_top_cited_this_year();  -- 'all'
--   -- expected: 5
-- =============================================================================
