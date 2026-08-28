-- =============================================================================
-- ORDER 180 (2026-08-28) — get_top_acceleration_articles: DEFAULT NULL på
-- filter_role så PostgREST kan matcha anrop som utelämnar parametern
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN.
--
-- BAKGRUND:
--
--   ORDER 180 punkt 3 (migration 20260828120000) lade argmax-branch för
--   filter_role IS NULL i CTE:erna. RPC:n hanterar null internt. MEN
--   signaturen har `filter_role text` UTAN DEFAULT — parametern är required.
--
--   Frontend (loadMomentum efter ORDER 180): `if (role && role !== 'all')
--   body.filter_role = toDbRole(role)`. I 'all'-läget utelämnas filter_role
--   från body. PostgREST matchar på supplied-parameter-namn; saknas required-
--   arg finns ingen matchande overload → 404 tillbaka till browsern.
--
--   Systerkällan `get_most_cited` (som fungerar i 'all'-läget) har
--   `filter_role text default null` i signaturen — matchar samma frontend-
--   pattern. Denna migration harmoniserar signaturen efter det etablerade
--   mönstret.
--
-- SIGNATUR-IDENTITY vs DEFAULTS:
--
--   Postgres function identity = arg types (in order). DEFAULTs är inte del
--   av identity — lagras i pg_proc.proargdefaults separat. Att lägga till
--   DEFAULT NULL på filter_role skapar INGEN ny overload. CREATE OR REPLACE
--   ersätter existerande funktion rent. Grants + comment preserverade.
--
-- SCOPE:
--
--   Enda funktionella ändringen är `filter_role text default null` på rad 44.
--   Function body oförändrad från 20260828120000. Duplikatet är nödvändigt
--   eftersom Postgres inte har ALTER FUNCTION ... SET DEFAULT-syntax —
--   default-ändring kräver hela body:n replaceras via CREATE OR REPLACE.
--
--   Systerfixet för get_top_cited_this_year i följande migration
--   (20260828150000_get_top_cited_this_year_default_null).
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
--   -- 1. Signaturen har DEFAULT NULL nu:
--   select pg_get_function_arguments(oid) from pg_proc
--    where proname='get_top_acceleration_articles'
--      and pronamespace='public'::regnamespace;
--   -- expected: "filter_role text DEFAULT NULL::text, min_prev integer
--   --            DEFAULT 20, min_relevance integer DEFAULT 6, limit_n
--   --            integer DEFAULT 5"
--
--   -- 2. Bara EN överlagring (defaults ändrar inte identity):
--   select count(*) from pg_proc
--    where proname='get_top_acceleration_articles'
--      and pronamespace='public'::regnamespace;
--   -- expected: 1
--
--   -- 3. Anrop utan filter_role fungerar nu:
--   select count(*) from public.get_top_acceleration_articles();
--   -- expected: 5 (matchar limit_n default, argmax-branch triggar)
--
--   -- 4. PostgREST-style anrop (från frontend) — kan simuleras med:
--   -- Ta emot body {min_prev: 20, min_relevance: 6, limit_n: 5} utan filter_role
--   -- via curl mot /rest/v1/rpc/get_top_acceleration_articles och verifiera
--   -- HTTP 200 istället för 404.
-- =============================================================================
