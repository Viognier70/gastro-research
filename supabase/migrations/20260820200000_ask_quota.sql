-- =============================================================================
-- ask_quota — per-user daily quota för Ask-vyn
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- BAKGRUND (ORDER 112, 2026-08-20):
--
--   ask-synth har idag ENDAST global daily budget (ask_budget_claim med
--   ASK_DAILY_BUDGET=100). En användare kan tömma taket för alla —
--   varken abuse-broms eller rimlig Free/Pro-differentiering.
--
--   ORDER 112: per-user dagsk-vot ovanpå den globala:
--     Free    3 frågor/dag
--     Pro     obegränsat inom global cap (999999-sentinel)
--     Anon    kräver sign-in (hanteras edge-side, inte i RPC:n)
--
-- MÖNSTER: identiskt med triad_quota_claim (bara dygns- istf månads-
-- perioden) — samma ops-muskelminne, samma retur-kod-kontrakt:
--   > 0        antal återstående gratis anrop efter DENNA claim
--     0        DENNA claim var sista lediga (nästa returnerar -1)
--    -1        kvoten redan slut, ingen ny räkning ökar count
--    999999    Pro (no-op — ingen räkning i tabellen)
--
-- ANONYM HANTERING: Ask är ett kärnvärde värt sign-in — Free-tier ger
-- 3/dag som lock för att skapa konto. Anon-fall hanteras edge-side
-- (HTTP 401 innan RPC:n anropas). Alternativ (klient-genererat anon_id
-- i localStorage, IP-fingerprint) är trivialt bypassbara — vi avstår.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.ask_quota (
  user_id    uuid        NOT NULL,
  day        date        NOT NULL DEFAULT current_date,
  count      int         NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, day)
);

-- INDEX PÅ user_id: primary key täcker det (user_id är första kolumn i PK).
-- Ingen extra index behövs. Row-hits per RPC-anrop är O(1) via PK-lookup.

COMMENT ON TABLE public.ask_quota IS
  'Per-user daily quota för Ask. Free får 3/dag, Pro obegränsat inom '
  'global budget. Hanteras av ask_quota_claim (ORDER 112, 2026-08-20).';


CREATE OR REPLACE FUNCTION public.ask_quota_claim(
  p_user_id uuid,
  p_is_pro  boolean
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_today date := current_date;
  v_count int;
  v_max   int  := 3;   -- Free-kvot per dygn. Bump här om policy ändras.
BEGIN
  -- Pro no-op — ingen skrivning, sentinel-return.
  IF p_is_pro THEN return 999999; END IF;

  -- Insert-or-increment. WHERE-klausulen ON CONFLICT blockar räkningen
  -- från att gå OVER v_max (RETURNING blir NULL istället → v_count NULL).
  INSERT INTO public.ask_quota (user_id, day, count)
       VALUES (p_user_id, v_today, 1)
  ON CONFLICT (user_id, day) DO UPDATE
     SET count = ask_quota.count + 1
     WHERE ask_quota.count < v_max
  RETURNING count INTO v_count;

  -- Kvoten slut idag → -1 (edge returnerar 402 quota_exceeded).
  IF v_count IS NULL THEN return -1; END IF;

  -- Antal återstående gratis efter denna claim.
  return v_max - v_count;
END
$function$;

REVOKE ALL    ON FUNCTION public.ask_quota_claim(uuid, boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ask_quota_claim(uuid, boolean) TO service_role;

COMMENT ON FUNCTION public.ask_quota_claim(uuid, boolean) IS
  'Per-user daily quota-claim för Ask. Free 3/dag, Pro obegränsat. '
  'Retur: >0 = återstående, -1 = slut, 999999 = Pro. Kallas EXKLUSIVT '
  'från ask-synth edge-fn (service_role). Speglar triad_quota_claim '
  '(ORDER 112, 2026-08-20).';


-- =============================================================================
-- SCHEMA-CACHE RELOAD
-- =============================================================================
NOTIFY pgrst, 'reload schema';


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Grants: bara service_role
--   SELECT has_function_privilege('anon',          'public.ask_quota_claim(uuid,boolean)', 'EXECUTE'); -- false
--   SELECT has_function_privilege('authenticated', 'public.ask_quota_claim(uuid,boolean)', 'EXECUTE'); -- false
--   SELECT has_function_privilege('service_role',  'public.ask_quota_claim(uuid,boolean)', 'EXECUTE'); -- true
--
--   -- 2. Free-tier: sekvens 2, 1, 0, -1, -1, -1
--   SELECT public.ask_quota_claim('00000000-0000-0000-0000-000000000001'::uuid, false);
--   -- expected: 2 (första claim: räknar från 0 → 1, återstår 3-1=2)
--   SELECT public.ask_quota_claim('00000000-0000-0000-0000-000000000001'::uuid, false);
--   -- expected: 1
--   SELECT public.ask_quota_claim('00000000-0000-0000-0000-000000000001'::uuid, false);
--   -- expected: 0
--   SELECT public.ask_quota_claim('00000000-0000-0000-0000-000000000001'::uuid, false);
--   -- expected: -1 (slut)
--   SELECT public.ask_quota_claim('00000000-0000-0000-0000-000000000001'::uuid, false);
--   -- expected: -1 (fortsatt slut, count-raden står kvar på 3)
--
--   -- 3. Pro no-op — ingen räkning
--   SELECT public.ask_quota_claim('00000000-0000-0000-0000-000000000002'::uuid, true);
--   -- expected: 999999
--   SELECT count(*) FROM public.ask_quota
--    WHERE user_id = '00000000-0000-0000-0000-000000000002';
--   -- expected: 0 (Pro-anrop skapar ingen rad)
--
--   -- 4. STÄDA testdata:
--   DELETE FROM public.ask_quota
--    WHERE user_id IN ('00000000-0000-0000-0000-000000000001',
--                      '00000000-0000-0000-0000-000000000002');
-- =============================================================================
