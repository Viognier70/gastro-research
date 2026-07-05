-- =====================================================================
-- Phase 3 · DEL 1 — account-bound trial (server truth, not localStorage)
-- =====================================================================
-- Replaces the localStorage-based reverse trial (trivially bypassable)
-- with a per-account trial recorded on public.profiles. Rule:
-- one account = one 14-day trial, ever. Enforced by the RPC below,
-- which is the ONLY write path — trial_used cannot be reset by the
-- user because there is no client-callable UPDATE surface for it.
--
-- Depends on:
--   * public.profiles.id = auth.users.id (backfilled 2026-07-05)
--   * profiles.is_pro (already in schema)
--   * profiles.display_name (added in 20260705120000_profiles_display_name.sql)
--
-- Effect on existing users:
--   * anders / somm (is_pro=true) → RPC returns already_pro, no change.
--   * All other rows have trial_used=false by default → each can start
--     ONE trial by calling start_trial() once.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Trial-state columns on profiles.
--    Additive, nullable timestamps + one boolean with a false default,
--    so existing rows remain unchanged and behave as "trial not yet used".
-- ---------------------------------------------------------------------
alter table public.profiles
  add column if not exists trial_started_at timestamptz,
  add column if not exists trial_ends_at    timestamptz,
  add column if not exists trial_used       boolean not null default false;

-- ---------------------------------------------------------------------
-- 2. start_trial() — the only path that flips trial_used to true.
--    SECURITY DEFINER runs as the function owner (postgres), so it can
--    write to profiles even though authenticated has no direct UPDATE
--    grant on trial_used. Hardened search_path stops any injection via
--    session-set schemas.
--
--    Returns a jsonb envelope the frontend can branch on without a
--    second round-trip.
-- ---------------------------------------------------------------------
create or replace function public.start_trial()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  uid  uuid := auth.uid();
  prof public.profiles%rowtype;
begin
  if uid is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  select * into prof from public.profiles where id = uid;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_profile');
  end if;

  if prof.is_pro then
    return jsonb_build_object(
      'ok', true,
      'reason', 'already_pro',
      'is_pro', true
    );
  end if;

  if prof.trial_used then
    return jsonb_build_object(
      'ok', false,
      'reason', 'trial_already_used',
      'trial_ends_at', prof.trial_ends_at
    );
  end if;

  update public.profiles
    set trial_used       = true,
        trial_started_at = now(),
        trial_ends_at    = now() + interval '14 days'
    where id = uid;

  return jsonb_build_object(
    'ok', true,
    'reason', 'trial_started',
    'trial_ends_at', now() + interval '14 days'
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Grants. Only signed-in users can call this; anon must never reach
--    it. service_role bypasses grants anyway (needed for admin tooling).
-- ---------------------------------------------------------------------
revoke all on function public.start_trial() from public, anon;
grant execute on function public.start_trial() to authenticated;

-- =====================================================================
-- Verification queries — run these after apply to confirm the shape
-- and grants landed correctly. Expected result in the right column:
--
--   select has_function_privilege('anon',          'public.start_trial()', 'EXECUTE'); -- false
--   select has_function_privilege('authenticated', 'public.start_trial()', 'EXECUTE'); -- true
--
--   -- Column presence and defaults
--   select column_name, data_type, is_nullable, column_default
--   from information_schema.columns
--   where table_schema='public' and table_name='profiles'
--     and column_name in ('trial_started_at','trial_ends_at','trial_used')
--   order by column_name;
--
--   -- Smoke test as a specific user (Supabase SQL editor → "Run as"):
--   -- select public.start_trial();
--   -- first call  → {"ok":true, "reason":"trial_started", "trial_ends_at":"..."}
--   -- second call → {"ok":false,"reason":"trial_already_used", ...}
-- =====================================================================
