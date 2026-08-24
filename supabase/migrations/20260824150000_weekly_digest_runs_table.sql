-- =============================================================================
-- ORDER 148 — public.weekly_digest_runs (heartbeat för veckobrevets schemaläggning)
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- BAKGRUND (2026-08-24):
--
--   send-weekly-digest.ts körs framöver av GitHub Actions varje måndag
--   06:00 UTC (.github/workflows/weekly-digest.yml). Utan heartbeat är
--   scheduler-hälsan tyst — en pausad workflow eller en misslyckad
--   Brevo-anrop ger noll signal in i systemet.
--
--   Denna tabell är ETT-RAD-PER-KÖRNING audit-logg. Scriptet skriver:
--     1. INSERT vid start (bara started_at + triggered_by)
--     2. PATCH vid slut (finished_at + recipients + sent_ok + sent_error)
--     3. PATCH i catch (finished_at + fatal_error) om main() throwar
--
--   Rader utan finished_at = körning som halkade av mid-flight (t.ex.
--   GHA runner OOM). Rader med fatal_error = katastrof-catch i main().
--   Rader med sent_error > sent_ok/2 = >50% Brevo-fail — antagligen
--   API-kvot eller nyckel-utlöpt.
--
-- ANVÄNDNING FRAMÅT:
--   gusto_health-vyn (utökas i 20260824160000_gusto_health_veckobrev.sql)
--   läser max(finished_at) WHERE fatal_error IS NULL som veckobrev_takt.
--   health-alert.digest_stalled-larmet triggar när alder_h > 192 (8 dygn)
--   med > 0 kandidater.
--
-- GRANTS: service_role hanterar INSERT+PATCH+SELECT från scriptet och
--   health-alert. authenticated SELECT för framtida admin-UI (ex. "senaste
--   körningar"-panel). anon får ingenting — audit-logg är inte publik.
-- =============================================================================


create table if not exists public.weekly_digest_runs (
  id            bigserial primary key,
  started_at    timestamptz not null default now(),
  finished_at   timestamptz,                     -- null = pågår eller kraschad
  recipients    int,                             -- fetchRecipients() length
  sent_ok       int,                             -- Brevo 2xx + last_digest_at uppdaterad
  sent_error    int,                             -- Brevo fail eller per-mottagare-fel
  fatal_error   text,                            -- main().catch → toppnivå-throw
  triggered_by  text not null default 'unknown'  -- 'gha' | 'manual'
);

comment on table public.weekly_digest_runs is
  'ORDER 148: heartbeat per send-weekly-digest-körning. En rad = en '
  'schemalagd (GHA) eller manuell (--send från terminal) körning.';

-- Index på started_at DESC för "senaste körningen"-queries från vyn
-- och admin-verktyg. Sorterad DESC eftersom det är den ordningen läsarna
-- kör efter.
create index if not exists ix_weekly_digest_runs_started_at_desc
  on public.weekly_digest_runs(started_at desc);

-- service_role skriver + läser. authenticated läser bara (framtida UI).
grant select, insert, update on public.weekly_digest_runs to service_role;
grant usage, select on sequence public.weekly_digest_runs_id_seq to service_role;
grant select on public.weekly_digest_runs to authenticated;


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Tabellen existerar + rätt kolumner:
--   \d public.weekly_digest_runs
--
--   -- 2. GRANTs korrekta:
--   select grantee, privilege_type from information_schema.role_table_grants
--    where table_schema = 'public' and table_name = 'weekly_digest_runs'
--    order by grantee, privilege_type;
--   -- expected: service_role har SELECT/INSERT/UPDATE, authenticated har SELECT
--
--   -- 3. Manuell smoke-INSERT (körs som service_role via SQL-editor):
--   insert into public.weekly_digest_runs (triggered_by) values ('manual');
--   select * from public.weekly_digest_runs order by id desc limit 1;
--   -- expected: 1 rad, started_at ~ now(), finished_at NULL, triggered_by='manual'
--
--   -- Städa smoke-raden:
--   delete from public.weekly_digest_runs where triggered_by = 'manual' and finished_at is null;
-- =============================================================================
