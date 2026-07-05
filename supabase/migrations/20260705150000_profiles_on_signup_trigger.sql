-- =====================================================================
-- Phase 3 · profiles auto-provisioning on new auth.users
-- =====================================================================
-- The frontend and start_trial() both key on public.profiles.id =
-- auth.users.id. Nothing was creating that row for new signups —
-- anders / somm had rows from Stripe / manual setup, which masked the
-- gap. Fresh signups landed with no profile at all, so:
--   * initAuth's `sb.from('profiles').select(...).eq('id', ...)` returns
--     null, isPro stays false, header shows unauthenticated state.
--   * start_trial() returns {ok:false, reason:'no_profile'} — the
--     trial can never start.
--
-- Fix: SECURITY DEFINER trigger that runs after every INSERT on
-- auth.users, creating the corresponding public.profiles row with
-- id, email, and any display_name already stashed in
-- raw_user_meta_data (handleAuth writes it there via signUp options.data).
-- ON CONFLICT DO NOTHING makes the trigger idempotent — if a row for
-- this user already exists (backfill re-run, manual insert), the
-- trigger is a no-op.
--
-- The backfill for existing broken accounts is in a separate migration
-- (20260705160000_profiles_backfill_missing.sql).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Trigger body.
--    SECURITY DEFINER runs as the function owner (postgres), so it can
--    write to public.profiles even though the row-creating context is
--    an anon-signup RLS session. Search path pinned to public + pg_temp
--    to defeat schema-injection.
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, email, display_name, is_pro, trial_used)
  values (
    new.id,
    new.email,
    nullif(trim(coalesce(new.raw_user_meta_data->>'display_name', '')), ''),
    false,
    false
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- Hygiene: nobody should call this directly. It only exists to be the
-- trigger body. service_role bypasses grants anyway (needed for admin
-- tooling, but this fn has no useful non-trigger call site).
revoke all on function public.handle_new_user() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Trigger.
--    Drop-if-exists first so re-running the migration replaces cleanly
--    (create or replace trigger doesn't exist in this Postgres version).
-- ---------------------------------------------------------------------
drop trigger if exists on_auth_user_created on auth.users;

create trigger on_auth_user_created
  after insert on auth.users
  for each row
  execute function public.handle_new_user();

-- =====================================================================
-- Verification — run after apply:
--
--   -- 1. Trigger is attached
--   select tgname, tgrelid::regclass, tgfoid::regprocedure
--     from pg_trigger
--    where tgname = 'on_auth_user_created';
--
--   -- 2. Simulate a signup and check that profiles gets a row.
--   -- (Do this via `supabase auth admin create user ...` or the
--   --  dashboard — direct INSERT into auth.users bypasses Supabase
--   --  auth machinery and is not recommended.)
--
--   -- 3. Confirm existing profiles are untouched (ON CONFLICT DO NOTHING)
--   select count(*) from public.profiles;   -- unchanged
-- =====================================================================
