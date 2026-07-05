-- =====================================================================
-- Phase 3 · DEL 4 — one email = one trial_signups row (stops double-mail)
-- =====================================================================
-- The welcome-email webhook fires on every INSERT into trial_signups.
-- Idempotency is currently enforced only by the welcome_sent_at column
-- on the row that fired the webhook, so if a SECOND row for the same
-- email lands (e.g. Anders re-typed his address, or the user came
-- through onboarding twice), the webhook fires again with a fresh
-- welcome_sent_at=NULL row → duplicate mail.
--
-- Fix in three steps:
--   1) Normalize existing rows: email → lower(email). Removes casing
--      skew so equal-except-case addresses count as duplicates.
--   2) Dedup preserving welcome_sent_at. Per email keep the "most
--      authoritative" row: already-sent > not-sent, then newest by
--      created_at, then smallest id as a deterministic tiebreak.
--      Dropping the sent row and keeping an unsent one would defeat
--      the whole point — the next webhook fire would re-send.
--   3) Enforce with a unique expression index on lower(email). Any
--      future INSERT that would collide raises a 23505 unique
--      violation → PostgREST returns 409, which the frontend swallows.
--
-- Frontend (index.html · saveTrialLead) is updated in the same PR to
-- lowercase the email before INSERT and treat 409 as "already saved".
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Normalize existing rows to lowercase.
-- ---------------------------------------------------------------------
update public.trial_signups
   set email = lower(email)
 where email <> lower(email);

-- ---------------------------------------------------------------------
-- 2. Dedup. row_number() over the ranking window; delete rows with
--    rn > 1 (the losers). Because lower(email) is normalized in step 1
--    a plain partition-by-email is safe.
-- ---------------------------------------------------------------------
with ranked as (
  select
    id,
    row_number() over (
      partition by email
      order by
        (welcome_sent_at is not null) desc,   -- keep already-sent
        created_at                    desc,   -- else newest
        id                            asc     -- deterministic tiebreak
    ) as rn
  from public.trial_signups
)
delete from public.trial_signups
 where id in (select id from ranked where rn > 1);

-- ---------------------------------------------------------------------
-- 3. Enforce.
-- ---------------------------------------------------------------------
create unique index if not exists trial_signups_email_uidx
  on public.trial_signups (lower(email));

-- =====================================================================
-- Verification queries — run after apply:
--
--   -- Should return zero rows (no duplicates):
--   select lower(email) as e, count(*) as c
--     from public.trial_signups
--    group by 1
--   having count(*) > 1;
--
--   -- Index should show up:
--   select indexname, indexdef
--     from pg_indexes
--    where schemaname = 'public'
--      and tablename  = 'trial_signups'
--      and indexname  = 'trial_signups_email_uidx';
--
--   -- Smoke test: this INSERT should succeed once, then fail with 23505:
--   -- insert into public.trial_signups (email, role, source)
--   --   values ('dedup-test@example.com', 'sommelier', 'sql_test');
--   -- insert into public.trial_signups (email, role, source)
--   --   values ('DEDUP-TEST@example.com', 'chef', 'sql_test');  -- 23505
-- =====================================================================
