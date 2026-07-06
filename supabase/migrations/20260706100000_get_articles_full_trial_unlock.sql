-- =====================================================================
-- Phase 3 · get_articles_full — unlock premium payload for active trials
-- =====================================================================
-- APPLIED MANUALLY IN PROD 2026-07-06.
-- This file is committed AFTER the fact so the repo matches deployed
-- state; do not re-run against a project that already has this version.
--
-- Symptom: users on an active trial (is_pro=false, trial_ends_at in the
-- future) saw the "Upgrade to Pro" upsell on every card and in the
-- article overlay instead of the ε/τ/φ payload. The client-side isPro
-- was correctly computed (is_pro OR trial_ends_at > now),
-- enrichWithPremiumIfPro was firing, but the RPC returned empty rows
-- because its Pro gate only accepted p.is_pro = true.
--
-- Fix: widen the Pro gate to also accept an active, unexpired trial.
-- Same signature, same SECURITY DEFINER, same grants — drop-in
-- replacement.
--
-- The prod definition of get_articles_full is plpgsql (if / return
-- query / return), not the sql-language variant an earlier draft of
-- this file used. This file now mirrors the exact prod body so
-- CREATE OR REPLACE is compatible on any environment cloned from prod.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.get_articles_full(article_ids uuid[])
RETURNS SETOF articles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  begin
    if exists (select 1 from public.profiles p
               where p.id = auth.uid()
                 and (p.is_pro = true
                      or (p.trial_ends_at is not null and p.trial_ends_at > now()))) then
      return query select * from public.articles where id = any(article_ids);
    else
      return;
    end if;
  end $function$;

-- Grants — re-asserted defensively. Unchanged from the initial deploy.
revoke all on function public.get_articles_full(uuid[]) from public, anon;
grant execute on function public.get_articles_full(uuid[]) to authenticated;

-- =====================================================================
-- Verification queries — for a fresh env, run after apply:
--
--   -- Grants intact
--   select has_function_privilege('anon',          'public.get_articles_full(uuid[])', 'EXECUTE'); -- false
--   select has_function_privilege('authenticated', 'public.get_articles_full(uuid[])', 'EXECUTE'); -- true
--
--   -- Smoke test as a trial user (Supabase SQL editor "Run as"):
--   -- Expected: 1 row, has_ep=true.
--   -- select id, episteme_sommelier is not null as has_ep
--   --   from public.get_articles_full(array['<uuid>'::uuid]);
-- =====================================================================
