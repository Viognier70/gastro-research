-- get_most_cited: score → ranking, inte gate. Modell 2, Lager 1 Del 1.
--
-- Bakgrund: efter b5e76ee (RPC-adoption + toDbRole-fix) kallas RPC:n med
-- filter_role='sensory_pro' etc. från frontend. Nuvarande WHERE gate:ar
-- rader med relevance_sci_<role> < 5 — dvs bara artiklar som passerat
-- roll-tröskeln syns.
--
-- Modell 2-beslut (gustema-relevans-diagnos.md): score RANKAR prominens,
-- GATE:ar inte existens. Inget blir permanent osynligt.
--
-- Praktisk kalibrering (verifierat 2026-07-17 via sanity-query):
--   articles WHERE citation_count > 0 → endast 123 rader
-- Denna RPC opererar på en pytteliten delmängd. Gate-valet spelade knappt
-- roll i praktiken; alternativ (B) valt: ta bort filter_role-WHERE-gaten,
-- behåll citation_count-sortering. Alla 123 är gastronomi-relevanta ändå
-- (passerade den binära irrelevant-gaten i relevance-check).
--
-- Ändringar vs 20260716120000-versionen:
--   1. Rad 137-147 i förra versionen tas bort — filter_role WHERE-gaten
--      med `>= 5`. topic/keyword-filter oförändrade.
--   2. filter_role-parametern behålls i signaturen som pass-through
--      (frontend rad 2849 skickar den fortfarande via toDbRole; att ta
--      bort parametern hade givit 400 "column not found").
--   3. relevance_score behålls i SELECT — informativt output, framtida
--      callers kan visa scoren utan att det påverkar sortering.
--   4. ORDER BY citation_count desc oförändrad — primär sortering.
--   5. filter_keyword läser fortfarande `keywords` (inte `claim_keywords`)
--      — den fixen låg redan i 20260716120000.
--
-- Framåt: Lager 1 Del 2 (keyword-backfill via OpenAlex) och Del 3
-- (frontend Feed/Explore has_episteme → irrelevant gate-byte) deployas
-- ihop som Grupp A per gustema-relevans-lager1-deployplan.md.
--
-- Grants: CREATE OR REPLACE preserverar existerande privilegier
-- (anon/authenticated/service_role satta för /rpc/get_most_cited sedan
-- ursprunglig deploy).

create or replace function public.get_most_cited(
  limit_n integer default 10,
  filter_topic text default null,
  filter_keyword text default null,
  filter_role text default null
)
returns table(
  id uuid,
  title text,
  journal text,
  year text,
  citation_count integer,
  topic text,
  url text,
  headline_en text,
  relevance_score integer
)
language sql
security definer
as $function$
  select
    a.id, a.title, a.journal, a.year,
    a.citation_count, a.topic, a.url, a.headline_en,
    coalesce(case filter_role
      when 'sensory_pro'         then a.relevance_sci_sensory_pro
      when 'culinary_pro'        then a.relevance_sci_culinary_pro
      when 'gastronomy_culture'  then a.relevance_sci_gastronomy_culture
      when 'hospitality_mgmt'    then a.relevance_sci_hospitality_mgmt
      when 'educator_researcher' then a.relevance_sci_educator_researcher
      else 0
    end, 0) as relevance_score
  from articles a
  where a.citation_count is not null
    and a.citation_count > 0
    and (filter_topic is null or a.topic = filter_topic)
    and (filter_keyword is null or filter_keyword = any(a.keywords))
  order by a.citation_count desc
  limit limit_n;
$function$;


-- =============================================================================
-- Verifiering efter apply (kör i SQL Editor eller `supabase db query --linked`):
--
--   -- 1. RPC signature oförändrad?
--   select pg_get_function_identity_arguments(oid)
--   from pg_proc where proname='get_most_cited'
--     and pronamespace='public'::regnamespace;
--   -- expected: "limit_n integer, filter_topic text, filter_keyword text, filter_role text"
--
--   -- 2. Roll-anrop returnerar även no-role-artiklar (om de finns i topp 5)?
--   select id, title, citation_count, relevance_score
--   from public.get_most_cited(10, null, null, 'sensory_pro');
--   -- expected: upp till 10 rader, sorterade på citation_count desc,
--   -- inkluderar artiklar med relevance_score < 5 om de har hög citation_count.
--
--   -- 3. Null-roll anrop oförändrat beteende:
--   select count(*) from public.get_most_cited(200, null, null, null);
--   -- expected: min(200, 123) ≈ 123 (alla artiklar med citation_count > 0).
--
--   -- 4. topic-filter fortsätter gate:a:
--   select count(distinct topic) from public.get_most_cited(500, null, null, null);
--   -- expected: > 1 (flera topics representerade).
