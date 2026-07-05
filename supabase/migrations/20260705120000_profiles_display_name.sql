-- =====================================================================
-- Phase 3 · DEL 0c — display_name column on profiles
-- =====================================================================
-- Free-text field. The user types their own name at signup (e.g.
-- "Dr. Crichton-Fock") and the UI prepends a role title chosen from a
-- fixed frontend mapping ("Sommelier Crichton-Fock", "Researcher
-- Dr. Crichton-Fock"). No role column is stored here.
--
-- Safe to run: additive, nullable, no default backfill. Existing
-- profiles keep display_name=NULL — the frontend falls back to the
-- email-initial avatar with no greeting text, so no user-visible
-- regression.
--
-- RLS on public.profiles already restricts writes; the frontend
-- updates this column via `.update(...).eq('id', auth.uid())` which
-- succeeds under the existing "authenticated can update own row"
-- policy. If that policy does not exist, the update is silently a
-- no-op and the avatar stays without a greeting — non-critical.
-- =====================================================================

alter table public.profiles
  add column if not exists display_name text;

-- =====================================================================
-- (The trial-state columns and start_trial() RPC come in the next
-- migration, 20260705130000_account_trial.sql, in DEL 1.)
-- =====================================================================
