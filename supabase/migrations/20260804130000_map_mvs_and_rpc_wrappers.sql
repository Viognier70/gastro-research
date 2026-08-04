-- =============================================================================
-- map_institution_coords_mv + map_institution_collabs_mv — materialiserade
-- vyer + tunna RPC-wrappers + pg_cron daglig REFRESH CONCURRENTLY.
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- BAKGRUND:
--
--   map_institution_coords() (från 20260804120000) tog 5 824 ms per anrop
--   i EXPLAIN ANALYZE. Solo i konsolen gick det precis, men vid sidladdning
--   körs tre RPC:er parallellt via Promise.all och den samlade tiden
--   sprängde PostgREST-timeout 57014. Kartan fick ingen data.
--
--   Detta är fjärde gången samma kedja i den här familjen:
--     1. Client-side aggregering över articles_public → PostgREST kapade
--        vid 1 000 rader (2026-08-02, map-vy).
--     2. → Byggd om till aggregerings-RPC (map_institution_stats +
--        map_country_stats).
--     3. → RPC:erna returnerade [] till anon: SECURITY DEFINER saknades
--        (2026-08-02 → 2026-08-04, retro-patchat i git).
--     4. → RPC:erna timeoutade vid parallell load (2026-08-04, nu).
--
--   Nästa steg är standardlösningen för dyra aggregat: precompute i en
--   materialiserad vy, refresh från cron, RPC blir en tunn SELECT över
--   den färdiga vyn (~1 ms).
--
-- ARKITEKTUR:
--
--   articles → MV (aggregat) → RPC (jsonb_agg SELECT) → frontend
--                    ↑
--             refresh_map_mvs() (pg_cron, daglig)
--
--   MV:erna byggs med UNIQUE INDEX på nyckeln så REFRESH MATERIALIZED
--   VIEW CONCURRENTLY funkar (utan indexet blockerar refresh alla
--   läsningar under refresh-varaktigheten).
--
--   Refresh-frekvens: dagligen 04:15 UTC. Datat ändras bara när nya
--   artiklar geokodas (Fas 1-3-flödet, körs manuellt) eller när daily-
--   fetch drar in nya OpenAlex-artiklar med coords från början.
--   Kartans läsare accepterar upp till 24h latens på nya prickar.
--
-- SEMANTIK ÄR ORÖRD:
--
--   MV-queries är IDENTISKA med RPC-kropparna i 20260804120000. Bara
--   materialiserings-lagret är nytt. Frontend anropar samma
--   map_institution_coords() / map_institution_collabs() — inga JS-
--   ändringar behövs.
--
-- SECURITY:
--
--   MV:erna ägs av function-owner (postgres/supabase_admin). RPC:erna
--   fortsätter vara SECURITY DEFINER så anon kan läsa via dem utan att
--   ha direct SELECT på MV:erna. REVOKE ALL på MV:erna för anon/
--   authenticated (RPC är enda access-vägen). service_role behåller
--   SELECT för manuell debugging.
-- =============================================================================


-- =============================================================================
-- 1. map_institution_coords_mv
-- =============================================================================
-- Identisk query med tidigare map_institution_coords() RPC. Grupperar på
-- OA-canonical coord.name, unnestar institution_coords[] via
-- jsonb_to_recordset. En rad per unik institution.
-- =============================================================================

drop materialized view if exists public.map_institution_coords_mv cascade;

create materialized view public.map_institution_coords_mv as
with inst_articles as (
  select
    coord.name              as name,
    coord.lat, coord.lng, coord.country,
    a.id                    as article_id,
    a.topic,
    a.institution_rank,
    a.primary_institution
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
  s.name,
  s.lat,
  s.lng,
  s.country,
  s.article_count,
  s.rank,
  coalesce(t.topics, '{}'::jsonb) as topics
from inst_summary s
left join topics_agg t on t.name = s.name;

-- UNIQUE INDEX obligatoriskt för REFRESH ... CONCURRENTLY.
create unique index map_institution_coords_mv_name_uk
  on public.map_institution_coords_mv (name);

revoke all on public.map_institution_coords_mv from public, anon, authenticated;
grant select on public.map_institution_coords_mv to service_role;


-- =============================================================================
-- 2. map_institution_collabs_mv
-- =============================================================================
-- Identisk query med tidigare map_institution_collabs() RPC. Inter-country
-- institutionspar per artikel med ≥2 coords. Sorted least/greatest på
-- namnen ger stabil nyckling.
--
-- Kan bli tyngre än coords-MV:n eftersom join:en är O(coord_count²) per
-- artikel. Mät med EXPLAIN ANALYZE (se verifieringssektionen) — om det
-- överstiger några sekunder på hela populationen kan refresh-schemat
-- behöva bli glesare eller köras off-peak.
-- =============================================================================

drop materialized view if exists public.map_institution_collabs_mv cascade;

create materialized view public.map_institution_collabs_mv as
with coord_rows as (
  select
    a.id,
    coord.name, coord.lat, coord.lng, coord.country
  from public.articles a
  cross join lateral jsonb_to_recordset(a.institution_coords)
    as coord(name text, lat numeric, lng numeric, country text)
  where a.irrelevant is not true
    and a.institution_coords is not null
    and jsonb_array_length(a.institution_coords) >= 2
    and coord.name    is not null
    and coord.lat     is not null
    and coord.lng     is not null
    and coord.country is not null
),
pairs as (
  select
    p1.id,
    least(p1.name, p2.name)     as inst_a,
    greatest(p1.name, p2.name)  as inst_b,
    case when p1.name < p2.name then p1.lat else p2.lat end as lat_a,
    case when p1.name < p2.name then p1.lng else p2.lng end as lng_a,
    case when p1.name < p2.name then p2.lat else p1.lat end as lat_b,
    case when p1.name < p2.name then p2.lng else p1.lng end as lng_b
  from coord_rows p1
  join coord_rows p2
    on p2.id = p1.id
   and p2.name > p1.name
   and p2.country <> p1.country
)
select
  inst_a, inst_b,
  max(lat_a) as lat1, max(lng_a) as lng1,
  max(lat_b) as lat2, max(lng_b) as lng2,
  count(*)::int as count
from pairs
group by inst_a, inst_b;

create unique index map_institution_collabs_mv_pair_uk
  on public.map_institution_collabs_mv (inst_a, inst_b);

revoke all on public.map_institution_collabs_mv from public, anon, authenticated;
grant select on public.map_institution_collabs_mv to service_role;


-- =============================================================================
-- 3. RPC-wrappers — läser MV:erna i stället för articles
-- =============================================================================
-- Samma jsonb-payload som förr; frontend märker ingen skillnad. Kvar-
-- håller SECURITY DEFINER så anon kan läsa via RPC utan att grantas
-- SELECT på MV:erna direkt (samma resonemang som pre-MV-versionen).
-- SET search_path behålls för defence-in-depth.
-- =============================================================================

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
        'name',           name,
        'lat',            lat,
        'lng',            lng,
        'country',        country,
        'article_count',  article_count,
        'rank',           rank,
        'topics',         topics
      )
    ),
    '[]'::jsonb
  )
  from public.map_institution_coords_mv
$function$;

grant execute on function public.map_institution_coords() to anon, authenticated, service_role;


create or replace function public.map_institution_collabs()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'inst_a', inst_a,
        'inst_b', inst_b,
        'lat1',   lat1,
        'lng1',   lng1,
        'lat2',   lat2,
        'lng2',   lng2,
        'count',  count
      )
    ),
    '[]'::jsonb
  )
  from public.map_institution_collabs_mv
$function$;

grant execute on function public.map_institution_collabs() to anon, authenticated, service_role;


-- =============================================================================
-- 4. refresh_map_mvs() + pg_cron daglig schemaläggning
-- =============================================================================
-- Refresh CONCURRENTLY (icke-blockerande läsning under refresh). Kräver
-- unique index på varje MV — se ovan.
--
-- service_role-only så inte anon triggerar en dyr refresh via /rest/rpc.
-- =============================================================================

create or replace function public.refresh_map_mvs()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  refresh materialized view concurrently public.map_institution_coords_mv;
  refresh materialized view concurrently public.map_institution_collabs_mv;
end;
$function$;

revoke all on function public.refresh_map_mvs() from public, anon, authenticated;
grant execute on function public.refresh_map_mvs() to service_role;

-- Idempotent — samma jobname ersätter befintlig schemaläggning vid
-- re-apply. Väljer 04:15 UTC (06:15 CEST) — låg trafik, långt från
-- backfill_abstracts_1min/backfill_affiliations_1min.
select cron.schedule(
  'map_mvs_refresh_daily',
  '15 4 * * *',
  $CRON$select public.refresh_map_mvs();$CRON$
);


-- =============================================================================
-- Verifiering (kör efter apply):
--
--   -- 1. Storlek på MV:erna:
--   select count(*) from public.map_institution_coords_mv;
--   -- expected: ~5-8k unika institutioner
--
--   select count(*) from public.map_institution_collabs_mv;
--   -- expected: ~500-2 000 inter-country par
--
--   -- 2. Örebro-sanity:
--   select * from public.map_institution_coords_mv
--    where name ilike '%örebro%';
--   -- expected: Örebro University med article_count ~27
--
--   -- 3. RPC-latens (var 5 824 ms för coords-RPC:n innan MV — ska nu vara ~1 ms):
--   explain analyze select public.map_institution_coords();
--   explain analyze select public.map_institution_collabs();
--
--   -- 4. MV-refresh-kostnad (mät före cron-schemat blir hett):
--   explain analyze refresh materialized view concurrently
--     public.map_institution_coords_mv;
--   explain analyze refresh materialized view concurrently
--     public.map_institution_collabs_mv;
--   -- Om collabs > 30 s: överväg glesare cron eller manuell trigger
--   -- efter Fas 3-körningar.
--
--   -- 5. Cron-jobbet:
--   select jobid, jobname, schedule, active
--     from cron.job where jobname = 'map_mvs_refresh_daily';
--   -- expected: 1 rad, active = true, schedule = '15 4 * * *'
--
--   -- 6. Grants:
--   select has_function_privilege('anon',
--     'public.map_institution_coords()', 'EXECUTE');            -- true
--   select has_function_privilege('anon',
--     'public.refresh_map_mvs()', 'EXECUTE');                   -- false
--   select has_table_privilege('anon',
--     'public.map_institution_coords_mv', 'SELECT');            -- false
-- =============================================================================
