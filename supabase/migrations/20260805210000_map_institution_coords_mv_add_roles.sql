-- =============================================================================
-- map_institution_coords_mv — lägg till roles-array per institution
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- BAKGRUND:
--
--   My topics-knappen i map-vyn filtrerade tidigare data.filter(i.rank <= 200)
--   — QS-ranking som proxy för rollrelevans. 41 av 33 818 artiklar har QS-rank,
--   så knappen gav 14 institutioner (elit-universitet clustered i Boston/
--   London/Zürich) med enorma överlappande cirklar.
--
--   Rätt beteende: filtrera på användarens roll, samma OR-logik som Feed:s
--   or=(has_episteme_${role}.is.true, has_sci_${role}.is.true) — dvs
--   institutioner som publicerar inom rollens ämnesområden.
--
-- LÖSNING:
--
--   Utöka MV:n med roles text[] per institution — set av 5 science-rollnamn
--   där MINST EN artikel har episteme-analys eller sci-score ≥ 5. bool_or()
--   över per-artikel-flaggor. Frontenden gör O(1)-lookup via Set(roles) för
--   filter, QS-rank behålls i hover för information (styr inget).
--
-- REFRESH-SEMANTIK: samma cron som tidigare (dagligen 04:15 UTC). Roles-
-- fältet är eventual-consistent på samma sätt som topics-jsonb. Nya
-- publikationer syns i My topics-filtret senast följande morgon.
-- =============================================================================

drop materialized view if exists public.map_institution_coords_mv cascade;

create materialized view public.map_institution_coords_mv as
with inst_articles as (
  select
    coord.name, coord.lat, coord.lng, coord.country,
    a.id as article_id,
    a.topic,
    a.institution_rank,
    a.primary_institution,
    -- Per-artikel per-roll: har den full TRIAD ELLER sci ≥ 5 för rollen?
    -- Samma OR-logik som Feed använder (or=has_episteme.is.true, has_sci
    -- .is.true) — matchar frontendens rollmedlemskaps-definition exakt.
    (a.episteme_sensory_pro         is not null or coalesce(a.relevance_sci_sensory_pro,         0) >= 5) as role_sensory_pro,
    (a.episteme_culinary_pro        is not null or coalesce(a.relevance_sci_culinary_pro,        0) >= 5) as role_culinary_pro,
    (a.episteme_gastronomy_culture  is not null or coalesce(a.relevance_sci_gastronomy_culture,  0) >= 5) as role_gastronomy_culture,
    (a.episteme_hospitality_mgmt    is not null or coalesce(a.relevance_sci_hospitality_mgmt,    0) >= 5) as role_hospitality_mgmt,
    (a.episteme_educator_researcher is not null or coalesce(a.relevance_sci_educator_researcher, 0) >= 5) as role_educator_researcher
  from public.articles a
  cross join lateral jsonb_to_recordset(a.institution_coords)
    as coord(name text, lat numeric, lng numeric, country text)
  where a.irrelevant is not true
    and a.institution_coords is not null
    and jsonb_array_length(a.institution_coords) > 0
    and coord.name is not null
    and coord.lat  is not null
    and coord.lng  is not null
),
topic_counts as (
  select name, topic, count(distinct article_id)::int as n
  from inst_articles
  where topic is not null
  group by name, topic
),
topics_agg as (
  select name, jsonb_object_agg(topic, n) as topics
  from topic_counts
  group by name
),
roles_agg as (
  -- En array per institution med de rollnamn där MINST EN artikel matchar.
  -- array_remove( ..., null) plockar bort de rollpositioner där bool_or=false.
  select
    name,
    array_remove(array[
      case when bool_or(role_sensory_pro)          then 'sensory_pro'         end,
      case when bool_or(role_culinary_pro)         then 'culinary_pro'        end,
      case when bool_or(role_gastronomy_culture)   then 'gastronomy_culture'  end,
      case when bool_or(role_hospitality_mgmt)     then 'hospitality_mgmt'    end,
      case when bool_or(role_educator_researcher)  then 'educator_researcher' end
    ], null) as roles
  from inst_articles
  group by name
),
inst_summary as (
  select
    name,
    max(lat)     as lat,
    max(lng)     as lng,
    max(country) as country,
    count(distinct article_id)::int as article_count,
    max(institution_rank) filter (where primary_institution = name) as rank
  from inst_articles
  group by name
)
select
  s.name, s.lat, s.lng, s.country, s.article_count, s.rank,
  coalesce(t.topics, '{}'::jsonb) as topics,
  coalesce(r.roles, array[]::text[]) as roles
from inst_summary s
left join topics_agg t on t.name = s.name
left join roles_agg  r on r.name = s.name;

-- UNIQUE INDEX obligatoriskt för REFRESH ... CONCURRENTLY.
create unique index map_institution_coords_mv_name_uk
  on public.map_institution_coords_mv (name);

revoke all on public.map_institution_coords_mv from public, anon, authenticated;
grant select on public.map_institution_coords_mv to service_role;


-- RPC-wrapper får roles-fältet
create or replace function public.map_institution_coords()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'name',          name,
        'lat',           lat,
        'lng',           lng,
        'country',       country,
        'article_count', article_count,
        'rank',          rank,
        'topics',        topics,
        'roles',         roles
      )
    ),
    '[]'::jsonb
  )
  from public.map_institution_coords_mv
$function$;

grant execute on function public.map_institution_coords() to anon, authenticated, service_role;

-- Immediate refresh så nya roles-fältet har data direkt efter apply
refresh materialized view public.map_institution_coords_mv;


-- =============================================================================
-- Verifiering (efter apply):
--
--   -- Fördelning per roll (hur många institutioner har MINST EN artikel per roll?):
--   select
--     count(*) filter (where 'sensory_pro'         = any(roles)) as sensory_pro,
--     count(*) filter (where 'culinary_pro'        = any(roles)) as culinary_pro,
--     count(*) filter (where 'gastronomy_culture'  = any(roles)) as gastronomy_culture,
--     count(*) filter (where 'hospitality_mgmt'    = any(roles)) as hospitality_mgmt,
--     count(*) filter (where 'educator_researcher' = any(roles)) as educator_researcher,
--     count(*) as total
--   from public.map_institution_coords_mv;
--
--   -- Snabb sanity — några exempel-institutioner:
--   select name, article_count, rank, roles
--     from public.map_institution_coords_mv
--    where name in ('Örebro University', 'Wageningen University & Research', 'Karolinska Institute')
--    order by article_count desc;
-- =============================================================================
