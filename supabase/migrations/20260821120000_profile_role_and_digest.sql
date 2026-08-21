-- =============================================================================
-- profiles: role + digest-fält (digest_enabled, digest_token, last_digest_at)
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- BAKGRUND (ORDER 120, 2026-08-21):
--
--   Rollen finns idag bara i localStorage (gs_role / gustoRole som chip-
--   slug). Servern vet inte vem som är Chef eller Sommelier, vilket
--   blockerar veckobrevet (och andra framtida server-side personaliserings-
--   flöden).
--
--   Denna migration lägger fyra kolumner på public.profiles:
--     role text                      — chip-slug, null = ingen roll vald
--     last_digest_at timestamptz     — dedupe mellan utskick (null = aldrig)
--     digest_enabled boolean         — avanmälnings-flagga (default true)
--     digest_token uuid              — publik unsub-token, ej kopplad till id
--
-- SÄKERHET för digest_token:
--   - gen_random_uuid() ger 128-bit random (kryptografiskt osäker predict:able,
--     men Supabases Postgres bygger på pg_uuidv4 som använder OS-CSPRNG — ok
--     för unsubscribe-token där entropi > 2^60 är tillräckligt mot brute-
--     force av mail-listor).
--   - Token är SEPARAT kolumn från id, avslöjar inte user_id.
--   - Ingen indexering av user_id via token (unique index på token, inte
--     composite) så en läckt token bara kan sätta digest_enabled=false
--     för den ena raden — inget lateralt movement mot profil-data.
--
-- BACKFILL: befintliga konton får ingen role satt (NULL = "ingen roll vald",
-- veckobrevet hoppar över dem). digest_token backfillas explicit så
-- unique-constraint kan sättas efteråt.
-- =============================================================================


-- =============================================================================
-- §1 — Lägg till kolumner (utan constraints först så backfill kan köra)
-- =============================================================================
alter table public.profiles
  add column if not exists role           text,
  add column if not exists last_digest_at timestamptz,
  add column if not exists digest_enabled boolean not null default true,
  add column if not exists digest_token   uuid;


-- =============================================================================
-- §2 — Backfilla digest_token för befintliga rader
-- =============================================================================
-- gen_random_uuid() som DEFAULT hade fungerat även för existing rows i
-- moderna Postgres (fast-path via volatile-default table rewrite), men
-- explicit UPDATE är säkrare och läsbar. Varje rad får en unik token.
update public.profiles
   set digest_token = gen_random_uuid()
 where digest_token is null;


-- =============================================================================
-- §3 — Sätt constraints efter backfill
-- =============================================================================
alter table public.profiles
  alter column digest_token set default gen_random_uuid(),
  alter column digest_token set not null;

-- Role whitelist. NULL = ingen roll vald (veckobrev hoppar över dem).
-- Chip-slug matchar frontend-värden i localStorage.gs_role.
-- Existing rader passerar (alla har role IS NULL efter §1).
alter table public.profiles
  drop constraint if exists profiles_role_chk;
alter table public.profiles
  add  constraint profiles_role_chk check (
    role is null or role in (
      'sommelier','chef','gastronomy','fb_manager','food_researcher'
    )
  );


-- =============================================================================
-- §4 — Unique index på digest_token för snabb /unsubscribe?t=<token>-lookup
-- =============================================================================
create unique index if not exists profiles_digest_token_uidx
  on public.profiles(digest_token);


-- =============================================================================
-- §5 — RLS-policy för SELECT (explicit; UPDATE-policy finns sedan
--       20260725130000_security_rls_grants.sql "Users can update own profile")
-- =============================================================================
drop policy if exists "Users can read own profile" on public.profiles;
create policy "Users can read own profile"
  on public.profiles for select
  to authenticated
  using ((select auth.uid()) = id);


-- =============================================================================
-- SCHEMA-CACHE RELOAD
-- =============================================================================
notify pgrst, 'reload schema';


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Kolumnerna finns med rätt typer och defaults
--   select column_name, data_type, is_nullable, column_default
--     from information_schema.columns
--    where table_schema='public' and table_name='profiles'
--      and column_name in ('role','last_digest_at','digest_enabled','digest_token')
--    order by column_name;
--   -- expected: 4 rader
--   --   digest_enabled: boolean, NO, true
--   --   digest_token:   uuid,    NO, gen_random_uuid()
--   --   last_digest_at: timestamp with time zone, YES, NULL
--   --   role:           text,    YES, NULL
--
--   -- 2. Alla befintliga rader har digest_token satt och unikt
--   select count(*)                              as total_rows,
--          count(digest_token)                   as with_token,
--          count(distinct digest_token)          as unique_tokens
--     from public.profiles;
--   -- expected: total_rows = with_token = unique_tokens
--
--   -- 3. Hur många konton saknar role efter migrationen?
--   --    (Detta är utgångsläget — brevet hoppar över dessa. En framtida
--   --    onboarding-nudge kan be dem välja roll för att aktivera veckobrev.)
--   select count(*) as missing_role
--     from public.profiles where role is null;
--
--   -- 4. Check-constraint tillåter bara whitelist + NULL
--   -- (kastar 23514 för ogiltig roll)
--   -- select public.profiles' id + role — smoke-test manuellt via UPDATE.
--
--   -- 5. RLS-policyer på profiles
--   select policyname, cmd, roles
--     from pg_policies
--    where schemaname='public' and tablename='profiles'
--    order by cmd, policyname;
--   -- expected: minst 2 rader:
--   --   "Users can read own profile"   | SELECT | {authenticated}
--   --   "Users can update own profile" | UPDATE | {authenticated}
--
--   -- 6. Unique index finns
--   select indexname from pg_indexes
--    where schemaname='public' and tablename='profiles'
--      and indexname='profiles_digest_token_uidx';
--   -- expected: 1 rad
-- =============================================================================
