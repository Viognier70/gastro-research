-- =============================================================================
-- openalex_institutions — lokal id → coord uppslagstabell + 3 RPC:er för
-- 3-fas-geokodning (institution_coords-backfill 2026-08-03)
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- BAKGRUND:
--
--   OpenAlex /works/-endpointen returnerar INTE geo på nested institutions,
--   bara id/display_name/country_code. Geo ligger på /institutions/{id}.
--   Tidigare geo-extraktion i daily-fetch OA-vägen + backfill-affiliations
--   var tysta felkällor (fixat 2026-08-02 i a39f9cb).
--
--   Geo-fältet fylls nu via 3-fas-flöde:
--     Fas 1: backfill missing institution_openalex_ids på articles
--            (scripts/backfill-institution-openalex-ids.ts, ~1 421 artiklar
--            per count 2026-08-02)
--     Fas 2: fyll openalex_institutions med geo per unikt id
--            (scripts/backfill-openalex-institutions.ts, ~3-5k id:n)
--     Fas 3: bulk-UPDATE articles.institution_coords via JOIN
--            (refresh_institution_coords RPC nedan)
--
-- SEPARAT FRÅN university_rankings: den tabellen är QS-ranking-source (name,
-- lat, lng, country_code) och används av backfill-institutions för QS-baserad
-- fuzzy namn-matchning. Har 453 rader, 5 % täckning. Behåll separat semantik.
--
-- SANITY-CAP I SCRIPTEN (15 000 i båda faserna):
--
--   Capen är en cirkuitbrytare mot körningar som malar oändligt av två
--   möjliga fel:
--     (a) TRIAD-gaten här nedan tas bort eller går sönder → populationen
--         hoppar från ~11 k till ~37 k icke-synliga institutioner och
--         quota-räknaren rinner iväg innan någon märker det.
--     (b) Idempotensen bryts (upsert lyckas men openalex_institutions_missing
--         returnerar samma id igen) → oändlig loop mot OpenAlex.
--   Capen skyddar därför OpenAlex-quotan och våra pengar mer än den skyddar
--   databasen.
--
--   Höj den INTE blint när populationen närmar sig taket. Kolla först:
--     1. Har TRIAD-populationen faktiskt vuxit (count TRIAD-artiklar)?
--     2. Har idempotensen brutits (samma id upsertat två gånger i loggen)?
--     3. Har någon lagt till en ny artikelkälla utan att TRIAD-pipelinen
--        hunnit ikapp?
--   Endast om (1) är förklaringen ska capen höjas. 2026-08-03 höjdes den
--   från 3 000 (Fas 1) resp 10 000 (Fas 2) till 15 000 båda — förra
--   estimatet 3-5k unika id underskattade hur många institutioner
--   ~19 767 TRIAD-artiklar täcker (faktiskt utfall Fas 2: 11 177).
-- =============================================================================

-- Städa upp obsolet RPC från Väg A-scriptet (935ff92 → superseded 2026-08-03).
-- Väg A antog att /works/-svaret hade geo på nested institutions — det gör
-- det inte. RPC:n institution_coords_backfill_candidates har inga anropare
-- längre; drop:as här så nästa DB-inspektion inte förvillar sig.
drop function if exists public.institution_coords_backfill_candidates(int);


create table if not exists public.openalex_institutions (
  id            text primary key,           -- "I122534668" (kort form, strippad prefix)
  display_name  text not null,
  lat           numeric,                     -- kan vara null om OpenAlex saknar geo
  lng           numeric,
  country_code  text,                        -- ISO 3166-1 alpha-2
  fetched_at    timestamptz not null default now()
);

create index if not exists idx_openalex_institutions_country
  on public.openalex_institutions (country_code);

revoke all on public.openalex_institutions from anon, authenticated;
grant select, insert, update on public.openalex_institutions to service_role;


-- =============================================================================
-- RPC 1: institution_openalex_ids_backfill_candidates
--
-- Fas 1-populationen — artiklar där institutions[] finns men
-- institution_openalex_ids saknas. Samma TRIAD-gate som authors-backfillen
-- (osynliga icke-TRIAD-rader kostar quota utan användarpåverkan).
-- =============================================================================

create or replace function public.institution_openalex_ids_backfill_candidates(p_limit int)
returns table(id uuid, url text, institutions text[])
language sql
stable
as $function$
  select id, url, institutions
  from public.articles
  where institution_openalex_ids is null
    and institutions is not null
    and array_length(institutions, 1) > 0
    and url like '%doi.org/%'
    and episteme_sensory_pro is not null
  order by id
  limit p_limit
$function$;

revoke all on function public.institution_openalex_ids_backfill_candidates(int) from public, anon, authenticated;
grant execute on function public.institution_openalex_ids_backfill_candidates(int) to service_role;


-- =============================================================================
-- RPC 2: openalex_institutions_missing
--
-- Fas 2-populationen — distinct id:n som finns i articles.institution_openalex_ids[]
-- men inte i openalex_institutions-tabellen än. Idempotent: nästa körning
-- returnerar bara de som fortfarande saknas.
-- =============================================================================

create or replace function public.openalex_institutions_missing(p_limit int)
returns table(id text)
language sql
stable
as $function$
  select distinct oid.id
  from public.articles a,
       lateral unnest(a.institution_openalex_ids) as oid(id)
  where a.institution_openalex_ids is not null
    and array_length(a.institution_openalex_ids, 1) > 0
    and a.episteme_sensory_pro is not null
    and a.irrelevant is not true
    and oid.id is not null
    and oid.id <> ''
    and not exists (
      select 1 from public.openalex_institutions oi where oi.id = oid.id
    )
  order by 1
  limit p_limit
$function$;

revoke all on function public.openalex_institutions_missing(int) from public, anon, authenticated;
grant execute on function public.openalex_institutions_missing(int) to service_role;


-- =============================================================================
-- RPC 3: refresh_institution_coords — Fas 3 bulk-UPDATE
--
-- JOINar articles × openalex_institutions via institution_openalex_ids[]-
-- elementen, bygger institution_coords JSONB från lookup-tabellens
-- lat/lng/country_code + articles.institutions[] för name. Använder
-- parallell-array-index (unnest WITH ORDINALITY) för att matcha namn mot id
-- på rätt position; kräver att arrays har samma längd (safety-gate nedan).
--
-- Idempotent: skriver bara om resultatet skiljer sig från nuvarande värde.
-- Returnerar antal uppdaterade rader. TRIAD-gate matchar map-universumet.
-- =============================================================================

create or replace function public.refresh_institution_coords()
returns int
language plpgsql
security definer
as $function$
declare
  v_count int;
begin
  with resolved as (
    select
      a.id as article_id,
      jsonb_agg(
        jsonb_build_object(
          'name',    a.institutions[oid.idx],
          'lat',     oi.lat,
          'lng',     oi.lng,
          'country', oi.country_code
        )
        order by oid.idx
      ) filter (where oi.lat is not null and oi.lng is not null) as coords
    from public.articles a
    cross join lateral unnest(a.institution_openalex_ids) with ordinality as oid(id, idx)
    left join public.openalex_institutions oi on oi.id = oid.id
    where a.institution_openalex_ids is not null
      and array_length(a.institution_openalex_ids, 1) > 0
      and a.institutions is not null
      -- Parallell-array-invariant: samma dedupe i extraktion → samma längd.
      -- Skydd mot fall som ändå slinker igenom (historisk data, race, etc).
      and array_length(a.institutions, 1) = array_length(a.institution_openalex_ids, 1)
      and a.episteme_sensory_pro is not null
      and a.irrelevant is not true
    group by a.id
  )
  update public.articles a
     set institution_coords = r.coords
    from resolved r
   where a.id = r.article_id
     and r.coords is not null
     and (a.institution_coords is distinct from r.coords);

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

revoke all on function public.refresh_institution_coords() from public, anon, authenticated;
grant execute on function public.refresh_institution_coords() to service_role;


-- =============================================================================
-- Verifiering (efter apply):
--
--   -- 1. Fas 1 populationen (baseline 2026-08-02: ~1 421):
--   select count(*) from public.institution_openalex_ids_backfill_candidates(50000);
--
--   -- 2. Fas 2 populationen (baseline: uppskattat 3-5k unika ids):
--   select count(*) from public.openalex_institutions_missing(50000);
--
--   -- 3. Fas 3 (dry-run — kör INTE update, verifiera bara population):
--   select count(*)
--     from public.articles a
--    where a.institution_openalex_ids is not null
--      and a.institutions is not null
--      and array_length(a.institutions, 1) = array_length(a.institution_openalex_ids, 1)
--      and a.episteme_sensory_pro is not null
--      and a.irrelevant is not true;
--   -- expected: samma storleksordning som map-universumet (~18 346 idag)
--
--   -- 4. Grants:
--   select has_function_privilege('service_role',
--     'public.institution_openalex_ids_backfill_candidates(int)', 'EXECUTE');  -- true
--   select has_function_privilege('service_role',
--     'public.openalex_institutions_missing(int)', 'EXECUTE');                  -- true
--   select has_function_privilege('service_role',
--     'public.refresh_institution_coords()', 'EXECUTE');                        -- true
-- =============================================================================
