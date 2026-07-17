-- Adopterar 8 RPCer som levt bara i Supabase-instansen in i git (lärdom 7).
--
-- Bakgrund: get_most_cited returnerade 400 42703 sedan chip-drop 2026-07-13.
-- RPC:n refererade `relevance_sci_sommelier` (och 4 andra droppade chip-
-- kolumner). Buggen upptäcktes för att frontend visade "Citations loading…"
-- permanent — RPC:n var osynlig för lint eftersom den bara fanns i Supabase
-- SQL Editor, inte i git.
--
-- Populationsaudit (pg_proc grep mot 81 droppade chip-namn + dead-column-
-- kontroll mot claim_keywords):
--   claim_pipeline_batch      REN
--   get_most_cited            5 chip-träffar (relevance_sci_{sommelier,chef,
--                             fb_manager,food_researcher,gastronomy}) + 1
--                             dead-column-read (claim_keywords)
--   get_sidebar_stats         REN
--   get_synthesis_stats       REN
--   get_trending_keywords     REN chip-mässigt — men läser dead claim_keywords
--                             (samma lärdom-7-rot som frontend-fix 3608abc)
--   match_articles            REN
--   triad_budget_claim        REN
--   triad_quota_claim         REN
--
-- Denna migration:
--   1. Adopterar alla 8 RPCer i git.
--   2. get_most_cited: (a) skär bort 5 chip-slug-armar (sommelier/chef/
--      gastronomy/fb_manager/food_researcher) — endast science-namn
--      accepteras nu. Frontend rad 2849 uppdateras samtidigt att kalla
--      toDbRole(role) före anropet (samma commit, annars bryts RPC:n åt
--      andra hållet). (b) filter_keyword-WHERE byter claim_keywords → keywords.
--   3. get_trending_keywords: FROM articles, unnest(claim_keywords) →
--      unnest(keywords). Fixar dead-column-read (253 rader → 18 352 rader).
--   4. Övriga 6 adopteras oförändrade (verifierat rena).
--
-- claim_keywords-fixen är symmetrisk med commit 3608abc (frontend-fix
-- 2026-07-15). Båda RPCerna missades då eftersom RPC:erna var utanför
-- git — precis den lärdom-7-populationen denna migration adopterar.
-- Att adoptera en halvtrasig RPC vore att bevara buggen: konsekvent
-- fix, samma rot.
--
-- Grants: CREATE OR REPLACE FUNCTION preserverar befintliga privilegier.
-- På live-databas är grants intakta (anon/authenticated/service_role är
-- redan satta för frontend-anropade RPCer, service_role för edge-function-
-- anropade). Vid fresh replay krävs egen grant-migration.
--
-- Uppföljning: scripts/lint-role-columns.sh utökas att skanna migrations/
-- nu när RPCerna bor där. Se gustema-order-lint-migrations-scan.md.


-- =============================================================================
-- 1. claim_pipeline_batch — batch-claim av processing_queue-rader åt pipeline.
--    Kallas från supabase/functions/pipeline/index.ts:30 med service_role.
-- =============================================================================

create or replace function public.claim_pipeline_batch(batch_size integer)
returns json
language plpgsql
as $function$
declare
  claimed json;
begin
  with claimed_ids as (
    select pq.id
    from processing_queue pq
    join articles a on a.id = pq.article_id
    where pq.status = 'pending'
      and pq.attempts < 5
      and (not pq.sci_done or not pq.triad_done)
      and a.irrelevant = false
      and a.abstract is not null
      and a.abstract != '[unavailable]'
      and length(a.abstract) > 50
    order by pq.priority desc, a.fetched_at desc
    limit batch_size
    for update skip locked
  ),
  updated as (
    update processing_queue
    set status = 'processing', updated_at = now()
    where id in (select id from claimed_ids)
    returning processing_queue.*,
      (select row_to_json(a) from articles a where a.id = processing_queue.article_id) as article
  )
  select json_agg(updated) into claimed from updated;
  return coalesce(claimed, '[]'::json);
end;
$function$;


-- =============================================================================
-- 2. get_most_cited — mest citerade artiklar per topic/keyword/roll.
--    Kallas från index.html:2850 (loadMostCited).
--
--    REWRITE 2026-07-16:
--    - Chip-slug-armar (sommelier/chef/fb_manager/food_researcher/gastronomy)
--      borttagna. RPC:n accepterar nu bara science-namn. Frontend rad 2849
--      uppdaterad att kalla toDbRole(role) innan anropet.
--    - filter_keyword-WHERE läser nu `keywords` (18 352 rader) i stället
--      för dead `claim_keywords` (253 rader).
-- =============================================================================

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
    and (
      filter_role is null or
      coalesce(case filter_role
        when 'sensory_pro'         then a.relevance_sci_sensory_pro
        when 'culinary_pro'        then a.relevance_sci_culinary_pro
        when 'gastronomy_culture'  then a.relevance_sci_gastronomy_culture
        when 'hospitality_mgmt'    then a.relevance_sci_hospitality_mgmt
        when 'educator_researcher' then a.relevance_sci_educator_researcher
        else 0
      end, 0) >= 5
    )
  order by a.citation_count desc
  limit limit_n;
$function$;


-- =============================================================================
-- 3. get_sidebar_stats — topic-count och journal-count till sidopanel.
--    Kallas från index.html:2793.
-- =============================================================================

create or replace function public.get_sidebar_stats()
returns json
language sql
security definer
as $function$
  select json_build_object(
    'topics', (
      select json_agg(row_to_json(t)) from (
        select topic as "0", count(*) as "1" from articles
        where topic is not null group by topic order by count(*) desc limit 20
      ) t
    ),
    'journals', (
      select json_agg(row_to_json(j)) from (
        select journal as "0", count(*) as "1" from articles
        where journal is not null and journal != ''
        group by journal order by count(*) desc limit 30
      ) j
    )
  );
$function$;


-- =============================================================================
-- 4. get_synthesis_stats — aggregerade counts från research_syntheses.
--    Kallas från index.html:3001.
-- =============================================================================

create or replace function public.get_synthesis_stats()
returns json
language sql
security definer
as $function$
  select json_build_object(
    'total', count(*),
    'convergence', count(*) filter (where evidence_type = 'convergence'),
    'divergence', count(*) filter (where evidence_type = 'divergence'),
    'strong', count(*) filter (where evidence_strength = 'strong')
  ) from research_syntheses;
$function$;


-- =============================================================================
-- 5. get_trending_keywords — trend-analys per keyword över åren.
--    Kallas från index.html:2815 och 3788.
--
--    FIX 2026-07-16: claim_keywords → keywords. articles.claim_keywords har
--    253 rader (dead sedan pipeline-writer bytte mål 2026-05-24); keywords
--    har 18 352. Symmetrisk med frontend-fixen i commit 3608abc.
-- =============================================================================

create or replace function public.get_trending_keywords(limit_n integer default 20)
returns table(
  keyword text,
  total_count bigint,
  this_year bigint,
  last_year bigint,
  five_year_avg numeric,
  trend_direction text,
  trend_pct numeric
)
language sql
security definer
as $function$
  with kw_counts as (
    select
      kw as keyword,
      count(*) as total_count,
      count(*) filter (where year::int >= 2025) as this_year,
      count(*) filter (where year::int = 2024) as last_year,
      count(*) filter (where year::int between 2020 and 2024) as five_year_total
    from articles, unnest(keywords) as kw
    where keywords is not null
      and array_length(keywords, 1) > 0
      and year is not null
      and year ~ '^\d{4}$'
    group by kw
    having count(*) >= 3
  )
  select
    keyword,
    total_count,
    this_year,
    last_year,
    round(five_year_total::numeric / 5, 1) as five_year_avg,
    case
      when last_year = 0 and this_year > 0 then 'new'
      when last_year = 0 then 'stable'
      when this_year::numeric / last_year > 1.3 then 'rising'
      when this_year::numeric / last_year < 0.7 then 'declining'
      else 'stable'
    end as trend_direction,
    case
      when last_year = 0 then 0
      else round(((this_year::numeric - last_year) / last_year) * 100)
    end as trend_pct
  from kw_counts
  order by total_count desc
  limit limit_n;
$function$;


-- =============================================================================
-- 6. match_articles — pgvector-similarity-sök över articles.embedding.
--    Kallas från supabase/functions/semantic-search/index.ts:113.
-- =============================================================================

create or replace function public.match_articles(
  query_embedding vector,
  match_threshold double precision default 0.5,
  match_count integer default 10
)
returns table(
  id uuid,
  title text,
  core_claim text,
  journal text,
  year text,
  topic text,
  similarity double precision
)
language sql
stable
as $function$
  select
    a.id,
    a.title,
    a.core_claim,
    a.journal,
    a.year,
    a.topic,
    1 - (a.embedding <=> query_embedding) as similarity
  from articles a
  where a.embedding is not null
    and 1 - (a.embedding <=> query_embedding) > match_threshold
  order by a.embedding <=> query_embedding
  limit match_count;
$function$;


-- =============================================================================
-- 7. triad_budget_claim — daglig TRIAD-budget (increment eller signal FULL).
--    Kallas från supabase/functions/triad-background/index.ts:122.
-- =============================================================================

create or replace function public.triad_budget_claim(p_budget integer)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_count int;
begin
  insert into public.triad_budget_log (day, count)
       values (current_date, 1)
  on conflict (day) do update
     set count = triad_budget_log.count + 1
     where triad_budget_log.count < p_budget
  returning count into v_count;

  if v_count is null then return -1; end if;
  return p_budget - v_count;
end
$function$;


-- =============================================================================
-- 8. triad_quota_claim — månadsvis TRIAD-kvot per user (Pro = obegränsat).
--    Kallas från supabase/functions/triad-on-demand/index.ts:203.
-- =============================================================================

create or replace function public.triad_quota_claim(
  p_user_id uuid,
  p_is_pro boolean
)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_month text := to_char(now(), 'YYYY-MM');
  v_count int;
  v_max   int  := 3;
begin
  if p_is_pro then return 999999; end if;

  insert into public.triad_quota (user_id, month, count)
       values (p_user_id, v_month, 1)
  on conflict (user_id, month) do update
     set count = triad_quota.count + 1
     where triad_quota.count < v_max
  returning count into v_count;

  if v_count is null then return -1; end if;
  return v_max - v_count;
end
$function$;


-- =============================================================================
-- Verifiering efter apply (kör i SQL Editor):
--
--   -- 1. Alla 8 RPCer finns i public?
--   select proname from pg_proc
--    where pronamespace = 'public'::regnamespace
--      and proname in ('claim_pipeline_batch','get_most_cited',
--                      'get_sidebar_stats','get_synthesis_stats',
--                      'get_trending_keywords','match_articles',
--                      'triad_budget_claim','triad_quota_claim')
--    order by proname;
--   -- expected: 8 rader
--
--   -- 2. get_most_cited returnerar utan 400 för science-roll?
--   select id, title, citation_count
--     from public.get_most_cited(5, null, null, 'sensory_pro');
--   -- expected: upp till 5 rader, ingen 42703
--
--   -- 3. get_most_cited returnerar för null-roll (topics-sidan)?
--   select count(*) from public.get_most_cited(10, null, null, null);
--   -- expected: 10 (om finns > 10 citerade artiklar)
--
--   -- 4. get_trending_keywords returnerar rikare data från keywords?
--   select count(*) from public.get_trending_keywords(50);
--   -- expected: markant fler unika keywords än före (18 352-basis vs 253)
--
--   -- 5. get_most_cited.filter_keyword matchar mot keywords, inte claim?
--   -- Ta ett vanligt keyword från trending och verifiera träffar:
--   select count(*) from public.get_most_cited(50, null, 'umami', null);
--   -- expected: > 0 om 'umami' finns i keywords-populationen
