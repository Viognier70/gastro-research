-- =============================================================================
-- profiles.digest_enabled default → false + handle_new_user läser roll+digest
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- BAKGRUND (ORDER 126, 2026-08-22):
--
--   digest_enabled defaultade till true (från 20260821120000_profile_role
--   _and_digest.sql) — alla nya konton prenumererade automatiskt utan att
--   ha valt det. Nu opt-in: default false, signup-formuläret sätter true
--   om användaren kryssar rutan.
--
--   Befintliga 47 rader rörs INTE — deras nuvarande värden (true) behålls
--   om de valt digest tidigare eller inte hunnit oped-outa via
--   /unsubscribe. Bara nya rader efter denna migration får default false.
--
--   handle_new_user-triggern uppdateras att läsa `role` och `digest_enabled`
--   ur raw_user_meta_data — signup-formuläret skickar dem via signUp:s
--   options.data (samma path som display_name idag).
--
-- VALIDATION AV role I TRIGGERN:
--   CHECK-constraint på profiles.role (från 20260821120000) tillåter bara
--   5 chip-slugs eller NULL. Om frontend skickar något annat → INSERT
--   failar → hela signup-transaktionen rullas tillbaka → user ser fel.
--   Frontend-picker exponerar bara whitelistade värden, så detta är
--   defensivt fångnät snarare än förväntad väg.
--
-- BAKÅTKOMPATIBILITET:
--   Gamla signup-vägar som inte skickar role/digest_enabled i metadata
--   → NULL/false — säker default. Ingen frontend-deploy krävs för att
--   migrationen ska vara safe.
-- =============================================================================


-- =============================================================================
-- §1 — ändra default på digest_enabled från true till false
-- =============================================================================
ALTER TABLE public.profiles
  ALTER COLUMN digest_enabled SET DEFAULT false;


-- =============================================================================
-- §2 — utöka handle_new_user att läsa role + digest_enabled från metadata
-- =============================================================================
-- CREATE OR REPLACE bevarar trigger-koppling (on_auth_user_created,
-- migration 20260705150000) — triggerns FOR EACH ROW-anrop av samma
-- funktionsnamn används oförändrad.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO public.profiles (
    id, email, display_name, role, digest_enabled, is_pro, trial_used
  )
  VALUES (
    NEW.id,
    NEW.email,
    NULLIF(TRIM(COALESCE(NEW.raw_user_meta_data->>'display_name', '')), ''),
    NULLIF(NEW.raw_user_meta_data->>'role', ''),
    COALESCE((NEW.raw_user_meta_data->>'digest_enabled')::boolean, false),
    false,
    false
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

-- Hygien: re-assertar grants (identiskt med 20260705150000 rad 55).
-- Trigger-funktionen ska aldrig anropas direkt.
REVOKE ALL ON FUNCTION public.handle_new_user() FROM public, anon, authenticated;


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Default är nu false
--   SELECT column_name, column_default
--     FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='profiles'
--      AND column_name='digest_enabled';
--   -- expected: column_default = false
--
--   -- 2. Befintliga rader oförändrade
--   SELECT digest_enabled, count(*)
--     FROM public.profiles
--    GROUP BY digest_enabled
--    ORDER BY digest_enabled DESC;
--   -- expected: samma antal true som innan migrationen (47 om ingen
--   -- pillat), 0 nya false om inget nytt konto skapats sedan
--
--   -- 3. Trigger-funktionen har rätt kropp
--   SELECT proname, pg_get_functiondef(oid)
--     FROM pg_proc
--    WHERE proname='handle_new_user'
--      AND pronamespace='public'::regnamespace;
--   -- expected: kroppen innehåller "role" och "digest_enabled"-referenser
-- =============================================================================
