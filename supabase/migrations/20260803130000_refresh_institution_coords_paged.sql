-- =============================================================================
-- refresh_institution_coords — pagerad Fas 3 (2026-08-03)
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- BAKGRUND:
--
--   Föregående version (utan p_limit, migrerad i 20260803120000) körde hela
--   populationen ~17 000 artiklar i en transaktion. SQL-editorns 60 s-timeout
--   dödade den efter ~195 UPDATE:s. Denna revision batchar via p_limit.
--
-- ÄNDRINGAR MOT FÖREGÅENDE:
--
--   - Signaturbyte: p_limit int default 5000 (drop + create; PostgreSQL
--     räknar defaultar inte i function-signaturen så OR REPLACE räcker inte).
--   - Batch-CTE med LIMIT + ORDER BY id → stabil paginering.
--   - EXISTS-gate: bara artiklar där MINST en institution har geo i
--     openalex_institutions. Nödvändigt för idempotens: utan gaten fastnar
--     artiklar vars institutioner alla saknar koord (noGeo=1 i Fas 2, plus
--     articles där alla ids är 404) i en evighetsloop eftersom UPDATE:n
--     kräver r.coords is not null.
--   - Övrig JOIN-logik och TRIAD/irrelevant-gates behållna.
--
-- ANVÄNDNING (kör upprepat tills 0 returneras):
--
--   select public.refresh_institution_coords();          -- default 5000
--   select public.refresh_institution_coords(2000);      -- mindre om 60s trång
--
-- FÖRVÄNTAD BATCHRÄKNING 2026-08-03:
--
--   Map-universum ~19 767 TRIAD-artiklar med institutions[]. Redan uppdaterat
--   2 584. Kvar ~17 000 varav uppskattat ~5-10 % faller ur EXISTS-gaten (id
--   som är 404 eller noGeo i openalex_institutions). Nettomål ~15-16 k rader.
--   Vid p_limit=5000 blir det 3-4 batchar plus en avslutande 0-retur.
-- =============================================================================

drop function if exists public.refresh_institution_coords();

create or replace function public.refresh_institution_coords(p_limit int default 5000)
returns int
language plpgsql
security definer
as $function$
declare
  v_count int;
begin
  with batch as (
    select a.id
    from public.articles a
    where a.institution_coords is null
      and a.institution_openalex_ids is not null
      and array_length(a.institution_openalex_ids, 1) > 0
      and a.institutions is not null
      -- Parallell-array-invariant: samma dedupe i extraktion → samma längd.
      and array_length(a.institutions, 1) = array_length(a.institution_openalex_ids, 1)
      and a.episteme_sensory_pro is not null
      and a.irrelevant is not true
      -- Idempotens-gate: minst en institution måste ha geo, annars kan
      -- UPDATE:n aldrig lyckas (r.coords blir null och filtreras bort).
      and exists (
        select 1
        from unnest(a.institution_openalex_ids) as oid(id)
        join public.openalex_institutions oi on oi.id = oid.id
        where oi.lat is not null and oi.lng is not null
      )
    order by a.id
    limit p_limit
  ),
  resolved as (
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
    join batch b on b.id = a.id
    cross join lateral unnest(a.institution_openalex_ids) with ordinality as oid(id, idx)
    left join public.openalex_institutions oi on oi.id = oid.id
    group by a.id
  )
  update public.articles a
     set institution_coords = r.coords
    from resolved r
   where a.id = r.article_id
     and r.coords is not null;

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

revoke all on function public.refresh_institution_coords(int) from public, anon, authenticated;
grant execute on function public.refresh_institution_coords(int) to service_role;


-- =============================================================================
-- Verifiering (efter apply):
--
--   -- Grants:
--   select has_function_privilege('anon',
--     'public.refresh_institution_coords(int)', 'EXECUTE');            -- false
--   select has_function_privilege('service_role',
--     'public.refresh_institution_coords(int)', 'EXECUTE');            -- true
--
--   -- Gamla no-arg-signaturen ska vara borta:
--   select has_function_privilege('service_role',
--     'public.refresh_institution_coords()', 'EXECUTE');
--     -- expect ERROR: function does not exist
--
--   -- Batch-population (ska minska mot 0 för varje anrop):
--   select count(*)
--     from public.articles a
--    where a.institution_coords is null
--      and a.institution_openalex_ids is not null
--      and a.institutions is not null
--      and array_length(a.institutions, 1) = array_length(a.institution_openalex_ids, 1)
--      and a.episteme_sensory_pro is not null
--      and a.irrelevant is not true
--      and exists (
--        select 1
--        from unnest(a.institution_openalex_ids) as oid(id)
--        join public.openalex_institutions oi on oi.id = oid.id
--        where oi.lat is not null and oi.lng is not null
--      );
-- =============================================================================
