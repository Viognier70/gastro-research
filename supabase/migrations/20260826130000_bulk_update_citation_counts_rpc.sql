-- =============================================================================
-- ORDER 175 — bulk_update_citation_counts RPC
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- BAKGRUND (2026-08-26):
--
--   ORDER 175:s citation-count-backfill kör två gånger i veckan via GHA
--   (måndag + torsdag 06:00 UTC). Population ~35 000 rader; per-rad PostgREST
--   PATCH tar ~585 ms → 5+ timmar för hela populationen, långt över GHA:s
--   60-minutersgräns.
--
--   Denna RPC gör batch-UPDATE över tusentals rader i EN SQL-transaktion,
--   och skippar server-side rader där värdet inte ändrats (IS DISTINCT FROM).
--   Client skickar en JSONB-array; server UPDATE:ar bara rader som faktiskt
--   får nytt värde och returnerar antalet.
--
-- PAYLOAD-FORMAT:
--   [ {"id": "<uuid>", "c": <integer>}, ... ]
--
--   Fält-namnen medvetet korta ("c" för count) — 5000-rads JSONB-arrayer
--   ligger under 400 KB och stannar under PostgREST body-limit (~1 MB
--   default). Vid 5000 rader per anrop klaras 35 000 på 7 batches.
--
-- RETUR: int — antal rader som faktiskt uppdaterades (inte samma som
--   payload-length; server hoppar över IS DISTINCT FROM-matchningar).
--
-- SEMANTIK:
--   - UPDATE bara där articles.citation_count IS DISTINCT FROM ny.c.
--     "IS DISTINCT FROM" behandlar NULL som ett värde: NULL → 5 räknas som
--     ändring, 5 → 5 räknas inte, NULL → NULL räknas inte, 5 → NULL räknas.
--   - Ingen INSERT-väg — okänt id i payload ignoreras tyst. Backfill-scriptet
--     kommer bara skicka id:n som existerar (fetch-based population).
--   - Ingen touch på övriga kolumner. citation_count är den enda som ändras.
--
-- SÄKERHET: SECURITY DEFINER + SET search_path = public, pg_temp. Behövs
--   för att exekvera från GHA (service_role) och för att backfill-scriptet
--   ska funka konsekvent oavsett caller.
--
-- STATEMENT_TIMEOUT: 60s. Backfill-scriptet chunkar payload till ≤5000 rader
--   per anrop; en UPDATE över 5000 rader med index på id tar <2s i praktiken.
--   60s är rejäl marginal om DB är belastad.
--
-- GRANTS: service_role EXECUTE (backfill-scriptet). authenticated + anon
--   får INGET — payload kan innehålla vilka id:n som helst, det är en
--   admin-operation.
-- =============================================================================


CREATE OR REPLACE FUNCTION public.bulk_update_citation_counts(payload jsonb)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
SET statement_timeout = '60s'
AS $function$
DECLARE
  updated_n int;
BEGIN
  WITH src AS (
    SELECT (e->>'id')::uuid AS id,
           (e->>'c')::int   AS c
      FROM jsonb_array_elements(payload) e
  ),
  updated AS (
    UPDATE public.articles a
       SET citation_count = s.c
      FROM src s
     WHERE a.id = s.id
       AND a.citation_count IS DISTINCT FROM s.c
    RETURNING a.id
  )
  SELECT count(*)::int INTO updated_n FROM updated;
  RETURN updated_n;
END
$function$;

REVOKE ALL ON FUNCTION public.bulk_update_citation_counts(jsonb) FROM public;
GRANT EXECUTE ON FUNCTION public.bulk_update_citation_counts(jsonb) TO service_role;

COMMENT ON FUNCTION public.bulk_update_citation_counts(jsonb) IS
  'ORDER 175 (2026-08-26): batch-UPDATE citation_count för många articles '
  'i en transaktion. Skippar server-side rader där värdet inte ändrats '
  '(IS DISTINCT FROM). Payload: [{"id":"<uuid>","c":<int>}, ...]. Returnerar '
  'antal rader som faktiskt fick nytt värde. Kallas av scripts/backfill-'
  'citation-counts.ts (default chunk-storlek 5000 rader per anrop).';


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Smoke-test med tom payload
--   SELECT public.bulk_update_citation_counts('[]'::jsonb);
--   -- expected: 0
--
--   -- 2. Smoke-test med ett obefintligt id
--   SELECT public.bulk_update_citation_counts(
--     '[{"id":"00000000-0000-0000-0000-000000000000","c":42}]'::jsonb
--   );
--   -- expected: 0 (id matchar ingen rad)
--
--   -- 3. Roundtrip: ta en riktig article, byt värde, byt tillbaka
--   -- (kräver att någon article har citation_count satt)
--   WITH pick AS (
--     SELECT id, citation_count FROM public.articles
--      WHERE citation_count > 0 LIMIT 1
--   )
--   SELECT public.bulk_update_citation_counts(
--     jsonb_build_array(
--       jsonb_build_object('id', pick.id, 'c', pick.citation_count + 1)
--     )
--   ) FROM pick;
--   -- expected: 1 (bytet gick igenom)
--
--   -- Byt tillbaka:
--   -- SELECT public.bulk_update_citation_counts(
--   --   jsonb_build_array(jsonb_build_object('id', '<uuid>', 'c', <original>))
--   -- );
--
--   -- 4. Grants:
--   SELECT has_function_privilege('service_role',
--     'public.bulk_update_citation_counts(jsonb)', 'EXECUTE'); -- true
--   SELECT has_function_privilege('anon',
--     'public.bulk_update_citation_counts(jsonb)', 'EXECUTE'); -- false
-- =============================================================================
