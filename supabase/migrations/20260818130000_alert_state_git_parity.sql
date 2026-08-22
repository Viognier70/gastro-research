-- =============================================================================
-- alert_state — git-paritet för operationell tabell (dokumenterad 2026-08-22)
-- =============================================================================
-- Tabellen skapades ad-hoc i prod någon gång före 2026-08-19 när health-alert
-- v4 introducerade delta-jämförelsen för ko_failed_alert. Ingen migration
-- fanns i git → denna fil dokumenterar strukturen som den ser ut i prod
-- (verifierat 2026-08-22: raden ko_failed = {"count":161} finns,
-- senast uppdaterad 2026-08-19 vid första v4-larmet).
--
-- IDEMPOTENT MOT PROD:
--   - CREATE TABLE IF NOT EXISTS → no-op om tabellen finns
--   - ENABLE ROW LEVEL SECURITY är idempotent
--   - REVOKE/GRANT är idempotent
--   - Ingen INSERT → befintliga rader rörs inte
--
-- FILEN ÄR OCKSÅ SÄKER MOT FRESH REPLAY (dev/local): då finns tabellen inte,
-- CREATE TABLE skapar den, health-alert fn:en kan sedan fylla den vid första
-- larmet utan att strukturen behöver justeras.
--
-- APPLICERA MANUELLT I SQL-EDITORN — augusti-migrationerna körs inte via
-- `supabase db push`.
--
-- =============================================================================
-- BAKGRUND (health-alert v4, 2026-08-18)
-- =============================================================================
--
-- ko_failed_alert larmade dagligen om samma 161 permanent failed rader i
-- tretton dygn utan att någon rad ökade — trettio SMS utan ett nytt faktum.
-- v4 introducerade delta-jämförelse: larmet fyras bara när talet stigit
-- sedan senast larmade värde. Detta värde sparas i alert_state.
--
-- Utan tabellen returnerar readLastAlerted null → fires-uttrycket blir
-- identiskt med v3-beteendet → SMS-spamen fortsätter. Bygg-guarden mot
-- deploy utan tabell är alltså denna migration.
--
-- =============================================================================
-- STRUKTUR (inferrad från health-alert/index.ts readLastAlerted/writeLastAlerted)
-- =============================================================================
--
--   key         text PRIMARY KEY  — larmtyp (t.ex. 'ko_failed')
--   value       jsonb NOT NULL    — larmspecifik nyttolast, t.ex. {"count":161}
--   updated_at  timestamptz NOT NULL DEFAULT now()
--
-- Användning:
--   SELECT value FROM alert_state WHERE key='ko_failed'   → readLastAlerted
--   INSERT ... ON CONFLICT (key) DO UPDATE SET value, updated_at
--                                                         → writeLastAlerted
--
-- =============================================================================
-- GRANTS / RLS
-- =============================================================================
--
-- Internal ops-tabell. Bara health-alert edge-fn (service_role) läser och
-- skriver. Ingen anledning för anon/authenticated att röra den — RLS
-- enabled utan policies ger implicit deny. service_role bypassar RLS så
-- fn:en fungerar oavsett policy-läge.
--
-- REVOKE FROM public rensar Supabase-defaultgranten som skapas automatiskt
-- när tabellen är i public schema. Explicit GRANT till service_role är
-- redundant (service_role har ALL by default) men görs för läsbarhet.
-- =============================================================================


CREATE TABLE IF NOT EXISTS public.alert_state (
  key        text        PRIMARY KEY,
  value      jsonb       NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.alert_state IS
  'Operationell state för health-alert edge-fn. Delta-jämförelse för larmtyper som ska larma på ökning, inte totalsumma. Skapad 2026-08-18 (v4).';
COMMENT ON COLUMN public.alert_state.key IS
  'Larmtyp, t.ex. ''ko_failed''. Primärnyckel.';
COMMENT ON COLUMN public.alert_state.value IS
  'Larmspecifik nyttolast (jsonb). För ko_failed: {"count": <int>} = senast larmade totalsumma.';
COMMENT ON COLUMN public.alert_state.updated_at IS
  'När raden senast skrevs. Sätts av edge-fn vid varje SMS-utskick, INTE vid cooldown/send_failed.';


-- RLS enabled utan policies = implicit deny för non-superuser-roller.
-- service_role bypassar RLS.
ALTER TABLE public.alert_state ENABLE ROW LEVEL SECURITY;


-- Idempotent grants. REVOKE public rensar default-granten.
REVOKE ALL ON TABLE public.alert_state FROM public, anon, authenticated;
GRANT  ALL ON TABLE public.alert_state TO service_role;


-- =============================================================================
-- VERIFIERING (kör efter apply — bör vara no-op mot prod):
--
--   -- 1. Struktur
--   SELECT column_name, data_type, is_nullable, column_default
--     FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='alert_state'
--    ORDER BY ordinal_position;
--   -- expected 3 rader: key text NO, value jsonb NO {}, updated_at timestamptz NO now()
--
--   -- 2. PK
--   SELECT conname, pg_get_constraintdef(oid)
--     FROM pg_constraint
--    WHERE conrelid='public.alert_state'::regclass AND contype='p';
--   -- expected: PRIMARY KEY (key)
--
--   -- 3. RLS
--   SELECT relname, relrowsecurity
--     FROM pg_class
--    WHERE relname='alert_state' AND relnamespace='public'::regnamespace;
--   -- expected: relrowsecurity = t
--
--   -- 4. Grants
--   SELECT grantee, privilege_type
--     FROM information_schema.role_table_grants
--    WHERE table_schema='public' AND table_name='alert_state'
--    ORDER BY grantee, privilege_type;
--   -- expected: bara service_role listad (+ eventuella superuser-roller);
--   -- anon och authenticated ska SAKNAS
--
--   -- 5. Befintlig data orörd
--   SELECT key, value, updated_at FROM public.alert_state ORDER BY key;
--   -- expected: ko_failed = {"count":161}, updated_at ~2026-08-19
-- =============================================================================
