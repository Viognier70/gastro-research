-- =============================================================================
-- ORDER 180 B (2026-08-27) — get_top_cited_this_year RPC
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN.
--
-- SYFTE:
--
--   Trio-panelen i Feed-sidopanelen behöver ett tredje mått som svarar
--   på "vad citeras mest RÄTT NU" — utan ratio-normalisering (Momentum)
--   och utan 5-års-kumulativ (Most cited).
--
--   Sorterar på cur_year_count ur citations_by_year — absoluta 2026-
--   citeringar. Nya artiklar med snabb 2026-uppmärksamhet lyfts fram,
--   även när de saknar 2025-baseline (skulle ge NULL i acceleration).
--
-- SKILLNAD MOT SYSKONEN:
--   get_most_cited              → sort total citation_count (5-års-cutoff)
--   get_top_acceleration        → sort ratio, min_prev-golv (accel > 1)
--   get_top_cited_this_year     → sort cur_year_count, min_cur-golv
--
-- SIGNATUR:
--   get_top_cited_this_year(
--     filter_role   text,
--     min_relevance integer default 6,
--     min_cur       integer default 3,        -- filtra enskilda-citerings-brus
--     limit_n       integer default 5
--   )
--
--   Inget min_prev-golv — vi mäter absolut aktuell aktivitet, inte
--   förändring. En 2026-artikel med 0 föregående-år och 8 hittills
--   ska rankas (och inte kunna rankas av get_top_acceleration).
--
-- JSONB-SÄKERHET: Samma MATERIALIZED CTE-mönster som ORDER 177 (bevisat
--   säker mot skalär-citations_by_year). Type-casts på integer-kolumner
--   för att undvika 42804 (bevisat problem i ORDER 177).
--
-- GRANTS: service_role + authenticated (framtida frontend + veckobrev-
--   möjlig utökning). anon får inget.
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


revoke all on function public.get_top_cited_this_year(text, integer, integer, integer) from public;
grant execute on function public.get_top_cited_this_year(text, integer, integer, integer) to service_role;
grant execute on function public.get_top_cited_this_year(text, integer, integer, integer) to authenticated;

comment on function public.get_top_cited_this_year(text, integer, integer, integer) is
  'ORDER 180 B (2026-08-27): topp-N artiklar per science-roll med mest '
  'absoluta 2026-citeringar (cur_year_count ur citations_by_year). Svarar '
  'på "vad citeras mest rätt nu", till skillnad från get_most_cited '
  '(kumulativt) och get_top_acceleration_articles (ratio). Golv min_cur '
  'filtrerar enskild-citerings-brus. MATERIALIZED CTE + type-casts som '
  'i ORDER 177.';


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Signatur:
--   select pg_get_function_identity_arguments(oid) from pg_proc
--    where proname='get_top_cited_this_year'
--      and pronamespace='public'::regnamespace;
--   -- expected: "filter_role text, min_relevance integer, min_cur integer, limit_n integer"
--
--   -- 2. Grants:
--   select has_function_privilege('service_role',
--     'public.get_top_cited_this_year(text,integer,integer,integer)', 'EXECUTE'); -- true
--   select has_function_privilege('anon',
--     'public.get_top_cited_this_year(text,integer,integer,integer)', 'EXECUTE'); -- false
--
--   -- 3. Smoke-test alla fem roller — ingen 42804, alla returnerar upp till 5:
--   select role, count(*) as n from (
--     select 'sensory_pro' as role, id from public.get_top_cited_this_year('sensory_pro') union all
--     select 'culinary_pro',           id from public.get_top_cited_this_year('culinary_pro') union all
--     select 'gastronomy_culture',     id from public.get_top_cited_this_year('gastronomy_culture') union all
--     select 'hospitality_mgmt',       id from public.get_top_cited_this_year('hospitality_mgmt') union all
--     select 'educator_researcher',    id from public.get_top_cited_this_year('educator_researcher')
--   ) t group by role order by role;
--
--   -- 4. Sort-korrekthet — cur_year_count monotont fallande:
--   select cur_year_count from public.get_top_cited_this_year('sensory_pro', 6, 3, 20);
--   -- expected: DESC-ordnad sekvens, alla >= 3.
-- =============================================================================
