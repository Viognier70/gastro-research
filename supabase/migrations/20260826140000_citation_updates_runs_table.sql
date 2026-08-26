-- =============================================================================
-- ORDER 175 — public.citation_updates_runs (heartbeat för citation-backfill)
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- BAKGRUND (2026-08-26):
--
--   scripts/backfill-citation-counts.ts körs framöver av GitHub Actions
--   måndag + torsdag 06:00 UTC (.github/workflows/citation-updates.yml).
--   Utan heartbeat är scheduler-hälsan tyst — en pausad workflow eller
--   sneed OpenAlex-API ger noll signal in i systemet.
--
--   Denna tabell är ETT-RAD-PER-KÖRNING audit-logg. Scriptet skriver:
--     1. INSERT vid start (bara started_at + triggered_by)
--     2. PATCH vid slut (finished_at + articles_checked + articles_updated
--        + api_errors)
--     3. PATCH i catch (finished_at + fatal_error) om main() throwar
--
--   Rader utan finished_at = körning som halkade av mid-flight (GHA OOM,
--   OpenAlex-hängning bortom vår timeout). Rader med fatal_error = katastrof-
--   catch i main(). articles_updated vs articles_checked-förhållandet visar
--   delta-storleken; typiskt 3-5 % efter första backfill är gjord.
--
-- ANVÄNDNING FRAMÅT:
--   gusto_health-vyn (utökas i 20260826150000_gusto_health_citations.sql)
--   läser max(finished_at) WHERE fatal_error IS NULL som citations_alder_h.
--   health-alert.citations_stalled-larmet triggar när alder_h > 96
--   (~4 dygn = en missad Mon+Thu-slot + halv dag).
--
--   Samma mönster som ORDER 148:s weekly_digest_runs — se
--   20260824150000_weekly_digest_runs_table.sql för prior art.
--
-- GRANTS: service_role hanterar INSERT+PATCH+SELECT från scriptet och
--   health-alert. authenticated SELECT för framtida admin-UI. anon får
--   ingenting — audit-logg är inte publik.
-- =============================================================================


create table if not exists public.citation_updates_runs (
  id                bigserial primary key,
  started_at        timestamptz not null default now(),
  finished_at       timestamptz,                     -- null = pågår eller kraschad
  articles_checked  int,                             -- antal artiklar fetch:ade från OpenAlex
  articles_updated  int,                             -- antal rader där citation_count faktiskt ändrades
  api_errors        int,                             -- 4xx/5xx eller nätverksfel från OpenAlex
  fatal_error       text,                            -- main().catch → toppnivå-throw
  triggered_by      text not null default 'unknown'  -- 'gha' | 'manual'
);

comment on table public.citation_updates_runs is
  'ORDER 175: heartbeat per backfill-citation-counts-körning. En rad = en '
  'schemalagd (GHA Mon+Thu) eller manuell (--apply från terminal) körning.';

-- Index på started_at DESC för "senaste körningen"-queries från gusto_health-
-- vyn och admin-verktyg.
create index if not exists ix_citation_updates_runs_started_at_desc
  on public.citation_updates_runs(started_at desc);

-- service_role skriver + läser. authenticated läser bara (framtida UI).
grant select, insert, update on public.citation_updates_runs to service_role;
grant usage, select on sequence public.citation_updates_runs_id_seq to service_role;
grant select on public.citation_updates_runs to authenticated;


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Tabellen existerar + rätt kolumner:
--   \d public.citation_updates_runs
--
--   -- 2. GRANTs korrekta:
--   select grantee, privilege_type from information_schema.role_table_grants
--    where table_schema = 'public' and table_name = 'citation_updates_runs'
--    order by grantee, privilege_type;
--   -- expected: service_role har SELECT/INSERT/UPDATE, authenticated har SELECT
--
--   -- 3. Manuell smoke-INSERT (körs som service_role via SQL-editor):
--   insert into public.citation_updates_runs (triggered_by) values ('manual');
--   select * from public.citation_updates_runs order by id desc limit 1;
--   -- expected: 1 rad, started_at ~ now(), finished_at NULL, triggered_by='manual'
--
--   -- Städa smoke-raden:
--   delete from public.citation_updates_runs where triggered_by='manual' and finished_at is null;
-- =============================================================================
