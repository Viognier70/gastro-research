-- =============================================================================
-- ORDER 177 (2026-08-27) — get_top_acceleration_articles RPC
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN.
--
-- SYFTE:
--
--   Veckobrevets nya "Gaining momentum"-avsnitt behöver rankad lista av
--   artiklar med kraftigast citations-acceleration för läsarens roll.
--   Kandidaterna filtreras hårt (golv 20 föregående-års-citeringar) så
--   listan inte domineras av 1987-2008-artiklar där 2 nya citeringar mot
--   1 föregående ger falsk 2×-signal.
--
-- DATATYP-VARNING (bevisat 2026-08-27):
--
--   articles.citations_by_year är JSONB. De flesta rader är arrays av
--   {year, cited_by_count}, men vissa rader innehåller skalärer eller
--   objekt. jsonb_array_elements() kastar runtime-error på icke-array.
--
--   Postgres reordrar WHERE-conditioner i valfri ordning inom samma scan.
--   Att skriva `WHERE jsonb_typeof(x)='array' AND jsonb_array_length(x)>0`
--   är INTE säkert — planer kan applicera length() först på skalärer.
--
--   Skydd här: WITH candidates AS MATERIALIZED (...) tvingar CTE:n att
--   exekvera fullständigt innan outer query. Inuti CTE:n används bara
--   operationer säkra på vilken jsonb-typ som helst (IS NOT NULL,
--   jsonb_typeof, casts på role-scalar-kolumner). Outer query opererar
--   sedan bara på array-rader — jsonb_array_elements blir säker.
--
-- SIGNATUR:
--
--   get_top_acceleration_articles(
--     filter_role   text,                          -- science-slug
--     min_prev      integer default 20,            -- golv: prev-year-cites
--     min_relevance integer default 6,             -- relevance_sci_<role>
--     limit_n       integer default 5              -- avsnittets kort-antal
--   )
--
--   Roll-parameter är science-slug ('sensory_pro' | 'culinary_pro' |
--   'gastronomy_culture' | 'hospitality_mgmt' | 'educator_researcher').
--   Skickas som filter_role från send-weekly-digest.ts, matchar övriga
--   role-RPC:er i codebasen (get_most_cited, spotlight_articles, etc).
--
--   min_relevance exponeras för framtida per-roll-override (t.ex. 8 för
--   'educator_researcher' där relevansen är nästan uniform post-ORDER 149
--   → tröskeln filtrerar knappt) utan att kräva ny migration.
--
-- SORTERING:
--   Primär: citation_acceleration DESC (magnituden i pace-ändring)
--   Sekundär: relevance DESC (bryter ties, ger academic-rollen försvarbar
--             sekundär rank när accel-värden ligger nära varandra)
--
-- GRANTS: service_role (kallar från send-weekly-digest.ts). authenticated
--   för framtida in-app "top movers"-panel. anon får inget — data-cost,
--   inte privacy — anon exponeras inte för denna typ av rankning.
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
    -- MATERIALIZED tvingar CTE:n att exekveras separat. Alla operationer
    -- här är typ-säkra oavsett citations_by_year:s form.
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
      -- Roll-gate: TRIAD för rollen krävs (matchar sectionA-semantik)
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
    -- Beräkna accel + prev/cur EN gång per rad. Här är
    -- jsonb_array_elements säker eftersom CTE ovan garanterar array-typ.
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
         s.core_claim, s.topic, s.citation_count,
         s.accel as acceleration,
         s.prev_ct as prev_year_count,
         s.cur_ct as cur_year_count,
         s.episteme, s.techne, s.phronesis, s.relevance
    from scored s
   where s.accel is not null
     and s.accel > 1                                 -- endast accelererande
     and s.prev_ct >= min_prev                       -- golv mot små-tal-flukes
   order by s.accel desc, s.relevance desc
   limit limit_n;
end
$function$;


revoke all on function public.get_top_acceleration_articles(text, integer, integer, integer) from public;
grant execute on function public.get_top_acceleration_articles(text, integer, integer, integer) to service_role;
grant execute on function public.get_top_acceleration_articles(text, integer, integer, integer) to authenticated;

comment on function public.get_top_acceleration_articles(text, integer, integer, integer) is
  'ORDER 177 (2026-08-27): topp-N artiklar per science-roll med största '
  'citation-acceleration. Golv min_prev citeringar föregående år för att '
  'undanta små-tal-flukes. MATERIALIZED CTE gör jsonb_typeof-filter säkert '
  'mot ordering av WHERE-conditioner. Kallas från send-weekly-digest.ts.';


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Signature:
--   select pg_get_function_identity_arguments(oid) from pg_proc
--    where proname='get_top_acceleration_articles'
--      and pronamespace='public'::regnamespace;
--   -- expected: "filter_role text, min_prev integer, min_relevance integer,
--   --            limit_n integer"
--
--   -- 2. Grants:
--   select has_function_privilege('service_role',
--     'public.get_top_acceleration_articles(text,integer,integer,integer)',
--     'EXECUTE'); -- true
--   select has_function_privilege('anon',
--     'public.get_top_acceleration_articles(text,integer,integer,integer)',
--     'EXECUTE'); -- false
--
--   -- 3. Smoke-test per roll (motsvarar diagnosen från ORDER 177):
--   select role, count(*) as topn from (
--     select 'sensory_pro' as role, id from public.get_top_acceleration_articles('sensory_pro') union all
--     select 'culinary_pro',           id from public.get_top_acceleration_articles('culinary_pro') union all
--     select 'gastronomy_culture',     id from public.get_top_acceleration_articles('gastronomy_culture') union all
--     select 'hospitality_mgmt',       id from public.get_top_acceleration_articles('hospitality_mgmt') union all
--     select 'educator_researcher',    id from public.get_top_acceleration_articles('educator_researcher')
--   ) t group by role order by role;
--   -- expected: 5 rader per roll (givet min_prev=20, min_relevance=6-diagnosen).
--
--   -- 4. Ingen kastning på skalär citations_by_year (sanity):
--   -- Diagnosen bevisade att skalärer finns i korpusen. Denna anrop måste
--   -- komma tillbaka utan error:
--   select id, acceleration, prev_year_count
--     from public.get_top_acceleration_articles('culinary_pro') limit 5;
--
--   -- 5. Verifiera att golv gate:ar korrekt:
--   select prev_year_count >= 20 as gate_ok, count(*)
--     from public.get_top_acceleration_articles('sensory_pro', 20, 6, 50)
--    group by prev_year_count >= 20;
--   -- expected: alla rader har gate_ok=true.
-- =============================================================================
