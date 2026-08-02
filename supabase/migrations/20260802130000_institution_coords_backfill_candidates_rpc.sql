-- =============================================================================
-- institution_coords_backfill_candidates — Väg A geokodningsbackfill
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push` (samma
-- content_gating chip-refs-block som stoppar replay från början).
--
-- BAKGRUND:
--
--   Map-vyn räknar sedan commit 86c6d20 via primary_institution, men
--   PLACERAR prickar från institution_coords[]. Coverage-copyn 2026-08-02:
--   2 389 geokodade av 29 166 TRIAD-artiklar med känd institution — 8 %.
--   Luckor och samarbetsmönster i kartan blir därför artefakter av vilka
--   artiklar som råkat bli geokodade.
--
--   backfill-affiliations (cron 1-min) predikatet är `institutions IS NULL`
--   och missar 27 407 rader som HAR institutions[] men saknar coords.
--   backfill-institutions läser från university_rankings (453 rader, byggd
--   för QS-ranking, saknar Örebro m.fl. — 5 % coverage).
--
--   Väg A: per-artikel OpenAlex DOI-lookup, extrahera authorships[]
--   .institutions[].geo direkt ur svaret. Väg B (populera universitäts-
--   tabell via OpenAlex /institutions/I…) skulle spara två tredjedelar av
--   anropen men kräver fuzzy namnmatchning mellan Scopus-svenska institu-
--   tions[]-strängar och OpenAlex-canonical namn — den familj av tyst
--   felkälla vi jagat i backfillen. 68 min mot 25 är irrelevant för ett
--   engångsjobb.
--
-- KONTRAKT (samma mönster som authors_backfill_candidates):
--
--   - order by id → stabil paginering + idempotent återupptagning (efter
--     lyckad PATCH är institution_coords non-null → filtreras bort)
--   - stable language sql, invoker-rätt (scriptet kör som service_role
--     som bypasser RLS ändå)
--   - grant execute till service_role only — admin-operation
--
-- TRIAD-GATE (episteme_sensory_pro is not null):
--
--   Samma resonemang som authors-backfillen. Icke-TRIAD-rader ligger i
--   articles men syns aldrig i Feed/overlay/map — att geokoda dem kostar
--   OpenAlex-quota utan användarpåverkan. Efterföljande daily-fetch-
--   inserts landar med coords direkt om OpenAlex har geo, så
--   populationen krymper monotont efter denna backfill.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.institution_coords_backfill_candidates(p_limit int)
RETURNS TABLE(id uuid, url text, institutions text[])
LANGUAGE sql
STABLE
AS $function$
  select id, url, institutions
  from public.articles
  where institutions is not null
    and array_length(institutions, 1) > 0
    and institution_coords is null
    and url like '%doi.org/%'
    and episteme_sensory_pro is not null
  order by id
  limit p_limit
$function$;

revoke all on function public.institution_coords_backfill_candidates(int) from public, anon, authenticated;
grant execute on function public.institution_coords_backfill_candidates(int) to service_role;


-- =============================================================================
-- Verifiering (efter apply):
--
--   -- Populationsstorleken:
--   select count(*) from public.institution_coords_backfill_candidates(50000);
--   -- expected: ~27 407 vid apply 2026-08-02; krymper efter varje batch
--
--   -- Grants:
--   select has_function_privilege('anon',
--     'public.institution_coords_backfill_candidates(int)', 'EXECUTE');   -- expect false
--   select has_function_privilege('authenticated',
--     'public.institution_coords_backfill_candidates(int)', 'EXECUTE');   -- expect false
--   select has_function_privilege('service_role',
--     'public.institution_coords_backfill_candidates(int)', 'EXECUTE');   -- expect true
-- =============================================================================
