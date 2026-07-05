-- =====================================================================
-- Phase 3 tail — welcome_sent_at column on trial_signups
-- =====================================================================
-- Idempotency key for the welcome-email edge function.
--   * NULL → welcome not yet sent; the fn will send and set the timestamp.
--   * NOT NULL → the fn short-circuits and returns {skipped:true}.
--
-- Safe to run: additive column, nullable, no default backfill. Existing
-- rows stay NULL, which means legacy signups WILL receive a welcome the
-- first time they trigger the fn — usually not what we want. If that's
-- a concern (Anders: bulk-sent already?), pre-set the timestamp for the
-- existing rows by running the commented-out UPDATE below BEFORE
-- wiring up the Database Webhook.
-- =====================================================================

alter table public.trial_signups
  add column if not exists welcome_sent_at timestamptz;

-- OPTIONAL — mark all existing rows as "already sent" so the fn will
-- only fire for future signups. Uncomment and run manually if desired.
-- update public.trial_signups
--   set welcome_sent_at = now()
--   where welcome_sent_at is null;

-- =====================================================================
-- No grants or RLS change: the edge fn talks to this table via the
-- service_role key, which bypasses both.
-- =====================================================================
