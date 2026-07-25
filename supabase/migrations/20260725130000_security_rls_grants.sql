-- =============================================================================
-- Säkerhetsfixar: RLS-policyer, grants, default privileges (2026-07-25)
-- =============================================================================
-- Allt nedan är kört direkt mot prod idag och verifierat.
-- KÖR INTE MOT PROD — det är redan gjort. Denna fil är för git-paritet.
--
-- BAKGRUND:
--
--   Schemat hade `grant all on all tables to anon, authenticated` på 20
--   tabeller, plus tre RLS-policyer som var öppna trots namn som antydde
--   motsatsen. Allvarligast:
--
--     - `Service role can update profiles` gällde ALL för rollen `public`
--       med qual=true — alla användarprofiler var läs- och skrivbara via
--       anon-nyckeln, som ligger publikt i index.html. Namn ljög, granten
--       var reell.
--     - `Public read subscribers` exponerade hela e-postlistan.
--     - `Public insert articles` tillät innehållsförgiftning från anon.
--
--   Verifierat efter apply: anon har nu endast SELECT plus INSERT på
--   trial_signups + subscribers. Pro-läge, saved_articles, artikelflöde
--   och nyhetsbrev (går via edge fn med service_role) fungerar.
--
-- OBSERVERAT MEN EJ ÅTGÄRDAT I DENNA MIGRATION:
--
--   Default privileges-raden för `supabase_admin` går inte att ändra från
--   SQL-editorn (owner-behörighet krävs som inte finns i den contexten).
--   Måste hanteras via infra/console om paranoia-nivån kräver det. Dagens
--   revoke på `postgres`-rollen täcker den vanliga writer-vägen.
-- =============================================================================


-- =============================================================================
-- 1. Droppa öppna policyer. Nio drops totalt — åtta enligt spec + noten om
--    att `Service role can update profiles` ersätts av #2 nedan.
-- =============================================================================

drop policy if exists "Service role can update profiles" on public.profiles;
drop policy if exists "Public read subscribers"          on public.subscribers;
drop policy if exists "Anon insert research_syntheses"   on public.research_syntheses;
drop policy if exists "Public insert fetch_log"          on public.fetch_log;
drop policy if exists "Public read fetch_log"            on public.fetch_log;
drop policy if exists "Public insert articles"           on public.articles;
drop policy if exists "Service insert fetch_progress"    on public.fetch_progress;
drop policy if exists "Service update fetch_progress"    on public.fetch_progress;


-- =============================================================================
-- 2. Ny profiles-policy. Ersätter den öppna `Service role can update
--    profiles`. Service_role bypasser RLS ändå — policyn behöver bara
--    tillåta att en inloggad användare uppdaterar SIN egen profil.
--
--    (select auth.uid()) i stället för auth.uid() följer PostgREST-
--    prestandaregeln: sub-select cachas per query, direkt call räknas om
--    per rad.
-- =============================================================================

create policy "Users can update own profile"
  on public.profiles for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);


-- =============================================================================
-- 3. Revokes. TRUNCATE/REFERENCES/TRIGGER på anon/authenticated var
--    kvarleva från `grant all` — inget legitim frontend-flöde behöver dem.
--    INSERT/UPDATE/DELETE dras helt från anon; två undantag återinförs
--    explicit där anon LEGITIMT skriver (trial_signups vid onboarding,
--    subscribers vid nyhetsbrev-signup).
-- =============================================================================

revoke truncate, references, trigger on all tables in schema public
  from anon, authenticated;

revoke insert, update, delete on all tables in schema public from anon;

grant insert on public.trial_signups to anon;
grant insert on public.subscribers   to anon;


-- =============================================================================
-- 4. Default privileges. Framtida tabeller skapade av `postgres` ska INTE
--    ge anon skrivrättigheter by default. Detta är brandväggen mot att en
--    ny tabell råkar återfå den gamla `grant all`-attityden.
--
--    Konsekvens (dokumenterad i supabase/README.md): en nyskapad tabell
--    ger anon 401 tills en explicit grant läggs på i migrationen som
--    skapar den.
-- =============================================================================

alter default privileges for role postgres in schema public
  revoke insert, update, delete, truncate on tables from anon;


-- =============================================================================
-- Verifiering (efter apply — redan kört 2026-07-25):
--
--   -- 1. Öppna policyer borta?
--   select schemaname, tablename, policyname, roles, cmd, qual
--     from pg_policies
--    where schemaname = 'public'
--      and policyname in (
--        'Service role can update profiles','Public read subscribers',
--        'Anon insert research_syntheses','Public insert fetch_log',
--        'Public read fetch_log','Public insert articles',
--        'Service insert fetch_progress','Service update fetch_progress'
--      );
--   -- expected: 0 rader
--
--   -- 2. Ny profiles-policy finns?
--   select policyname, cmd, roles, qual, with_check
--     from pg_policies
--    where schemaname='public' and tablename='profiles'
--      and policyname='Users can update own profile';
--   -- expected: 1 rad, cmd=UPDATE, roles={authenticated}
--
--   -- 3. Anon-privileges: bara SELECT + två explicita INSERTs?
--   select table_name, privilege_type
--     from information_schema.role_table_grants
--    where grantee='anon' and table_schema='public'
--      and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE',
--                             'REFERENCES','TRIGGER')
--    order by table_name, privilege_type;
--   -- expected: INSERT on trial_signups, INSERT on subscribers (only)
--
--   -- 4. Default privileges för postgres?
--   select defaclrole::regrole, defaclnamespace::regnamespace, defaclacl
--     from pg_default_acl
--    where defaclnamespace = 'public'::regnamespace
--      and defaclrole = 'postgres'::regrole;
-- =============================================================================
