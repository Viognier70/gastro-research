-- =============================================================================
-- set_digest_enabled(p_token, p_enabled) — RPC för publik unsub/undo
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- BAKGRUND (ORDER 121, 2026-08-21):
--
--   Veckobrevet skickas som transaktionsmejl med en avanmälningslänk
--   /unsubscribe?t=<digest_token>. Mottagaren ska kunna klicka länken
--   utan att logga in — vilket kräver ett skrivpath för anon mot
--   profiles.digest_enabled. Direkt UPDATE är inte möjligt eftersom
--   RLS-policyn "Users can update own profile" kräver auth.uid() = id.
--
--   Denna RPC är den ENDA skrivvägen anon har mot digest_enabled.
--   SECURITY DEFINER kör som postgres (bypasser RLS); "auth"-mekanismen
--   är kunskap om digest_token (128-bit random uuid från
--   20260821120000_profile_role_and_digest.sql).
--
-- SÄKERHET:
--   - Token är enda match-nyckeln. Ingen (email, id, session, cookie)
--     kollas. Kunskap om token = rätt att slå av/på DENNA rads
--     digest_enabled och NGT ANNAT.
--   - Bara `digest_enabled`-kolumnen skrivs. Ingen data-läsning
--     tillbaka — även callern med rätt token får inte veta något
--     annat om raden (email, is_pro, role etc.).
--   - Returnerar antal uppdaterade rader (0 eller 1). Callern (edge
--     fn) använder det för att logga token-missar mot abuse men
--     VISAR ALDRIG skillnaden till user (neutralt meddelande oavsett).
--   - Ingen rate-limit på RPC-nivå. Brute-force av UUID-rymden är
--     opraktiskt (2^128); orimliga attacker mot enskild token skulle
--     ändå bara sätta samma värde på samma rad → no-op.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.set_digest_enabled(
  p_token   uuid,
  p_enabled boolean
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_count integer;
BEGIN
  -- Ingen guard mot NULL-token: gen_random_uuid()-defaulten på profiles
  -- garanterar att inga befintliga rader har NULL, och ett NULL-p_token
  -- från callern matchar 0 rader (WHERE digest_token = NULL är alltid NULL,
  -- filtrerar bort allt) — samma neutralt-utfall som en okänd token.
  UPDATE public.profiles
     SET digest_enabled = p_enabled
   WHERE digest_token = p_token;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END
$fn$;

-- Anon får kalla RPC:n. authenticated + service_role också (för admin-verktyg
-- och framtida in-app unsub-UI). REVOKE FROM public först för hygien.
REVOKE ALL    ON FUNCTION public.set_digest_enabled(uuid, boolean) FROM public;
GRANT EXECUTE ON FUNCTION public.set_digest_enabled(uuid, boolean) TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.set_digest_enabled(uuid, boolean) IS
  'Publik RPC för avanmälning/ångra av veckobrev. Kunskap om digest_token '
  '= behörighet. Returnerar antal uppdaterade rader (0 eller 1); callern '
  'visar aldrig skillnaden till användaren. Anropas av edge-fn unsubscribe '
  '(ORDER 121, 2026-08-21).';


-- =============================================================================
-- SCHEMA-CACHE RELOAD
-- =============================================================================
NOTIFY pgrst, 'reload schema';


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. RPC finns med rätt signatur
--   SELECT proname, pronargs FROM pg_proc
--    WHERE pronamespace = 'public'::regnamespace
--      AND proname = 'set_digest_enabled';
--   -- expected: 1 rad, pronargs=2
--
--   -- 2. Grants
--   SELECT has_function_privilege('anon',          'public.set_digest_enabled(uuid,boolean)', 'EXECUTE'); -- true
--   SELECT has_function_privilege('authenticated', 'public.set_digest_enabled(uuid,boolean)', 'EXECUTE'); -- true
--   SELECT has_function_privilege('service_role',  'public.set_digest_enabled(uuid,boolean)', 'EXECUTE'); -- true
--
--   -- 3. Okänd token → 0 (neutral)
--   SELECT public.set_digest_enabled('00000000-0000-0000-0000-000000000000'::uuid, false);
--   -- expected: 0
--
--   -- 4. Giltig token på testprofil — round-trip. Ersätt med en verklig
--   --    token från din test-profil (kan tas ur SELECT digest_token FROM
--   --    profiles WHERE email='test@...').
--   -- SELECT public.set_digest_enabled('<real-token>'::uuid, false);
--   -- expected: 1
--   -- SELECT digest_enabled FROM profiles WHERE digest_token='<real-token>';
--   -- expected: false
--   -- SELECT public.set_digest_enabled('<real-token>'::uuid, true);
--   -- expected: 1
--   -- SELECT digest_enabled FROM profiles WHERE digest_token='<real-token>';
--   -- expected: true
-- =============================================================================
