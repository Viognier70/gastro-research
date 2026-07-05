-- =====================================================================
-- Phase 3 · one-time backfill of missing public.profiles rows
-- =====================================================================
-- Companion to 20260705150000_profiles_on_signup_trigger.sql. The
-- trigger only fires on NEW auth.users inserts; it does nothing for
-- accounts already created without a matching profiles row (the
-- oru.se test account, and any other signup between the profiles
-- table's creation and the trigger's installation).
--
-- This migration walks auth.users and inserts a profiles row for every
-- user that doesn't already have one. ON CONFLICT DO NOTHING makes
-- it safe to re-run and safe if the trigger has partially caught up.
--
-- Fields:
--   id            = auth.users.id (preserves the FK invariant the rest
--                   of the app depends on)
--   email         = auth.users.email
--   display_name  = raw_user_meta_data->>'display_name' when present
--                   (handleAuth passes it via signUp options.data);
--                   NULL otherwise — the header falls back to the
--                   email-initial avatar in that case.
--   is_pro        = false     — no paying customer would be missing a
--                               profile row (Stripe path always creates
--                               one), so false is the safe default.
--   trial_used    = false     — every backfilled account gets its one
--                               shot at start_trial().
-- =====================================================================

insert into public.profiles (id, email, display_name, is_pro, trial_used)
select
  u.id,
  u.email,
  nullif(trim(coalesce(u.raw_user_meta_data->>'display_name', '')), ''),
  false,
  false
from auth.users u
where not exists (
  select 1 from public.profiles p where p.id = u.id
)
on conflict (id) do nothing;

-- =====================================================================
-- Verification — run after apply:
--
--   -- 1. Every auth.users now has a profiles row
--   select count(*) as missing
--     from auth.users u
--    where not exists (select 1 from public.profiles p where p.id = u.id);
--   -- expected: 0
--
--   -- 2. Specific broken account resolved
--   select p.id, p.email, p.is_pro, p.trial_used, p.trial_ends_at
--     from public.profiles p
--    where p.email = 'anders.crichton-fock@oru.se';
--   -- expected: one row, is_pro=false, trial_used=false
-- =====================================================================
