-- =============================================================================
-- map_institution_coords() + map_institution_collabs() — server-side
-- aggregering av kart-datat efter coord-backfillen 2026-08-03.
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- BAKGRUND:
--
--   Frontend loadCoordArticles paginerade articles_public i sidor om 1 000
--   rader. Med 20 994 coord-havande artiklar krävdes 21 fetchar (PAGE_MAX=20
--   slog i taket). Mätt 2026-08-04: kartan visade 1 006 institutioner, dvs
--   ~1 000 av 20 994 artiklar hade nått fram. Örebro University visade
--   count=3 i hover trots att RPC:n map_institution_stats säger 28 —
--   dot:ens count kom från coord-datats topics-summa, inte från RPC:n,
--   eftersom coord-loopen bara hade 3 Örebro-artiklar i den trunkerade
--   populationen.
--
--   Fjärde trunkeringsbuggen i samma familj den här veckan (author-backfill,
--   authors-backfill skarpkörning, map_institution_stats, nu coord-fetchen).
--   Se docs/postgrest-caps.md för generell notering.
--
-- LÖSNING:
--
--   Två nya RPC:er som aggregerar server-side och returnerar jsonb (en rad,
--   bypass av 1 000-cappen som gäller per rad, inte per fält):
--
--     map_institution_coords()   — [{name, lat, lng, country, article_count,
--                                     rank, topics}, ...]
--                                  En rad per unik OA-canonical institution
--                                  som förekommer i minst en articles.
--                                  institution_coords[].name.
--
--     map_institution_collabs()  — [{inst_a, inst_b, lat1, lng1, lat2, lng2,
--                                     count}, ...]
--                                  Inter-country institutionspar som
--                                  co-authored samma artikel. Motsvarar
--                                  frontendens tidigare client-side collab-
--                                  build (byggd från institution_coords[]
--                                  per artikel med ≥2 coords).
--
--   map_institution_stats() lämnas kvar (används inte längre av kartan —
--   dot-count kommer nu från map_institution_coords.article_count — men
--   kan vara användbar för framtida per-primary_institution-vyer).
--
-- UNIVERSUM:
--
--   irrelevant is not true (matchar articles_public exponerings-gate)
--   institution_coords non-null + non-empty
--   coord.name/lat/lng non-null (filtrerar noGeo-institutioner som Fas 2
--     upsertade utan koord)
--
--   INGEN TRIAD-gate — kartan visar hela pipeline-outputen, inte bara
--   Sonnet-analyserade. Coverage-copyn har SIN egen TRIAD-gate.
--
-- SEMANTIK-SKIFTE MOT PRE-REFACTOR:
--
--   Innan: dot-count = instCounts[key] || 0 där instCounts kom från
--          map_institution_stats (primary_institution). Institutioner vars
--          OA-canonical namn INTE matchade någon primary_institution-sträng
--          (K1.1c) fick count=0 och filtrerades bort.
--   Efter: dot-count = antal artiklar som HAR denna OA-canonical i sin
--          institution_coords[]. K1.1c-varianten försvinner som problem —
--          alla dots har positiva count. Semantiken är dessutom mer
--          intuitiv för kartan ("hur många forskningsartiklar är
--          associerade med denna institution i kartan").
--
-- SECURITY DEFINER + SET search_path (fixat 2026-08-04 efter manuell alter
-- i prod — utan detta returnerar RPC:erna [] till anon):
--
--   Båda funktionerna läser public.articles DIREKT (via cross join lateral
--   jsonb_to_recordset(a.institution_coords)). Anon har GRANT SELECT bara
--   på public.articles_public (view:en), inte på public.articles-tabellen
--   (verifierat 20260731120000: grant select on public.articles to
--   authenticated — anon utelämnad avsiktligt).
--
--   Som INVOKER körs RPC:erna med anons rättigheter → permission denied
--   på public.articles → PostgREST 500 → callMapRpc returnerar [].
--   Som DEFINER körs de med function-ägarens rättigheter (postgres/
--   supabase_admin) → läser articles fritt.
--
--   Säkerhetsanalys: OK att göra DEFINER här eftersom bägge funktionerna
--   returnerar AGGREGATED counts + koordinater — ingen row-exponering av
--   RLS-skyddade fält, ingen SQL-injection-yta (inga parametrar). Samma
--   mönster som map_institution_stats/map_country_stats manuellt patchades
--   till 2026-08-02.
--
--   search_path fixeras till public, pg_temp för att stänga
--   sökväg-hijack-attacker (schema-shadowing på icke-schema-qualificerade
--   namn). All access i kroppen är public.-qualified redan, så detta är
--   defence-in-depth mer än strikt nödvändigt.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- map_institution_coords()
-- ---------------------------------------------------------------------------
-- Grupperar på coord.name (OA-canonical display_name från
-- openalex_institutions via Fas 2-upsert). lat/lng/country är
-- deterministiska per name eftersom Fas 3 skriver samma värden till
-- alla artiklars institution_coords[] för samma OA-id. `rank` sätts när
-- coord.name matchar primary_institution i minst en artikel (institution_
-- rank är per artikel men konstant per institution). `topics` som
-- jsonb-objekt så frontenden kan välja dominant_topic + hover-breakdown
-- utan ytterligare rundtur.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.map_institution_coords()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  with inst_articles as (
    select
      coord.name              as inst_name,
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
    select inst_name, topic, count(distinct article_id)::int as n
    from inst_articles
    where topic is not null
    group by inst_name, topic
  ),
  topics_agg as (
    select inst_name, jsonb_object_agg(topic, n) as topics
    from topic_counts
    group by inst_name
  ),
  inst_summary as (
    select
      inst_name,
      max(lat)     as lat,
      max(lng)     as lng,
      max(country) as country,
      count(distinct article_id)::int as article_count,
      max(institution_rank) filter (where primary_institution = inst_name) as rank
    from inst_articles
    group by inst_name
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'name',           s.inst_name,
        'lat',            s.lat,
        'lng',            s.lng,
        'country',        s.country,
        'article_count',  s.article_count,
        'rank',           s.rank,
        'topics',         coalesce(t.topics, '{}'::jsonb)
      )
    ),
    '[]'::jsonb
  )
  from inst_summary s
  left join topics_agg t on t.inst_name = s.inst_name
$function$;

grant execute on function public.map_institution_coords() to anon, authenticated, service_role;


-- ---------------------------------------------------------------------------
-- map_institution_collabs()
-- ---------------------------------------------------------------------------
-- Inter-country institutionspar: två institutioner som förekommer i samma
-- artikels institution_coords[] och som har olika country. Motsvarar
-- frontendens tidigare O(n²) client-side collabMap-loop.
--
-- Nyckling via least()/greatest() på namnen så samma par grupperas
-- oavsett var i coord-arrayen de dyker upp. lat/lng-fälten är konsistenta
-- per name (samma resonemang som ovan), så max() ger deterministiska
-- värden.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.map_institution_collabs()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
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
  ),
  agg as (
    select
      inst_a, inst_b,
      max(lat_a) as lat_a, max(lng_a) as lng_a,
      max(lat_b) as lat_b, max(lng_b) as lng_b,
      count(*)::int as c
    from pairs
    group by inst_a, inst_b
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'inst_a', inst_a,
        'inst_b', inst_b,
        'lat1',   lat_a,
        'lng1',   lng_a,
        'lat2',   lat_b,
        'lng2',   lng_b,
        'count',  c
      )
    ),
    '[]'::jsonb
  )
  from agg
$function$;

grant execute on function public.map_institution_collabs() to anon, authenticated, service_role;


-- =============================================================================
-- Verifiering (efter apply):
--
--   -- 1. map_institution_coords storlek + Örebro-sample:
--   select jsonb_array_length(public.map_institution_coords());
--   -- expected: ~5-8k unika institutioner (jämför med tidigare kartans
--   -- 1 006 = trunkeringsgränsen)
--
--   select value from jsonb_array_elements(public.map_institution_coords())
--    where value->>'name' ilike '%örebro%';
--   -- expected: Örebro University med article_count ~27
--
--   -- 2. map_institution_collabs storlek:
--   select jsonb_array_length(public.map_institution_collabs());
--   -- expected: ~500-2 000 inter-country par
--
--   -- 3. Grants:
--   select has_function_privilege('anon',
--     'public.map_institution_coords()', 'EXECUTE');            -- true
--   select has_function_privilege('anon',
--     'public.map_institution_collabs()', 'EXECUTE');           -- true
-- =============================================================================
