-- =============================================================================
-- backfill_progress.direction + seed av forward-jobb (2026-08-05)
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- SYFTE:
--
--   backfill_progress-jobb sveper hittills bara BAKÅT mot MIN_YEAR (1970).
--   De fyra fritext-jobben har hittat 0 nya artiklar på månader — historiken
--   är mättad. Samtidigt visar årsfördelningen av TRIAD-analyserade artiklar
--   att 2026 är nästan tom (254 rader mot ~4 000 vid 2025-års takt).
--
--   Lösning: framåtriktade jobb per kärntidskrift (source-id). Ett forward-
--   jobb ökar year när innevarande år är uttömt (nästa år) och stannar
--   kvar på current-year för att fånga nya publikationer när cron kör.
--   Aldrig completed = true — forward är en evig bevakning.
--
-- ANSTÄNDIGHETSFRÅGA MOT OPENALEX:
--
--   När ett forward-jobb ligger på innevarande år och alla sidor är
--   uttömda skulle en naiv implementation refetcha sida 0 varje tick
--   (~20 anrop per jobb per tick, 7 jobb, var 3:e min = 67 000 anrop/dygn
--   mot en gratistjänst). Fixen ligger i daily-fetch:s fetchOpenAlexPage:
--   forward-jobb får `from_publication_date:date(last_run)-1` som filter,
--   så vi bara hämtar det som publicerats sedan senaste sväng. 1-dygns
--   överlapp är dedupe-säkerhet mot klockglidning; url-unique-constraint
--   fångar dubbletter.
--
--   Filtret appliceras BARA på forward-jobb. Backward-svepen behöver
--   ingen sådan optimering — de går alltid till nästa år/nästa sida.
--
-- SCHEMA-ÄNDRING:
--
--   1. Ny kolumn direction text (default 'backward') så existerande jobb
--      inte får förändrat beteende.
--   2. Byte av unique-constraint från (source, identifier) till
--      (source, identifier, direction). Låter samma journal ha både
--      historiskt svep och framåtbevakning parallellt.
--   3. advance_backfill_progress-RPC:n får en p_direction-parameter
--      (default 'backward') och on-conflict-target byter till trippeln.
--      p_direction har DEFAULT så PostgREST fortfarande kan anropa
--      funktionen med 6 params — gammal daily-fetch fungerar under
--      deployen mellan migration och edge-fn-push.
-- =============================================================================

-- 1. Ny kolumn — default backward så existerande rader inte påverkas.
alter table public.backfill_progress
  add column if not exists direction text
    not null default 'backward'
    check (direction in ('backward', 'forward'));

-- 2. Byte av unique-constraint. Namn på existerande constraint är okänt utan
--    DB-inspektion; städa båda kandidatformer defensivt. IF EXISTS = no-op
--    om de inte finns.
alter table public.backfill_progress
  drop constraint if exists backfill_progress_source_identifier_key;
drop index if exists public.backfill_progress_source_identifier_key;

create unique index if not exists uq_backfill_progress_source_identifier_direction
  on public.backfill_progress (source, identifier, direction);


-- 3. RPC-uppdatering. Behåll signatur bakåtkompatibel via default på p_direction
--    så gamla anrop utan direction fortfarande går genom under deploy-fönstret.
create or replace function public.advance_backfill_progress(
  p_source     text,
  p_identifier text,
  p_year       int,
  p_page       int,
  p_added      int,
  p_completed  boolean,
  p_direction  text default 'backward'
)
returns void
language sql
as $function$
  insert into public.backfill_progress
    (source, identifier, direction, current_year, current_page, total_fetched, completed, last_run)
  values
    (p_source, p_identifier, p_direction, p_year, p_page, p_added, p_completed, now())
  on conflict (source, identifier, direction) do update set
    current_year  = excluded.current_year,
    current_page  = excluded.current_page,
    total_fetched = coalesce(backfill_progress.total_fetched, 0) + excluded.total_fetched,
    completed     = excluded.completed,
    last_run      = excluded.last_run;
$function$;

revoke all on function public.advance_backfill_progress(text, text, int, int, int, boolean, text)
  from public, anon, authenticated;
grant execute on function public.advance_backfill_progress(text, text, int, int, int, boolean, text)
  to service_role;


-- 4. Städa Appetite (S126804734) backward — enligt verifiering 2026-08-05
--    står den på year=2016, page=2, 0 hämtade sedan länge. 4 397 rader från
--    Appetite finns redan i DB via äldre pipeline-väg (fritext-jobben).
--    Markera completed så nästa cron inte plockar den; forward-varianten
--    (nästa steg) tar över bevakning framåt.
update public.backfill_progress
   set completed = true
 where source = 'openalex'
   and identifier = 'S126804734'
   and direction = 'backward';


-- 5. Seed: 7 forward-jobb för kärntidskrifter. current_year = 2026 (dagens år),
--    last_run = null så första körningen är full-year sweep (ingen from_
--    publication_date-filter tillämpas). Följande cron-tick ligger på samma
--    år, last_run satt → from_publication_date-filtret kicker in och håller
--    volymen nere.
--
--    Source-id:n verifierade mot OpenAlex 2026-08-05:
--      S194662844   Food Quality and Preference       ( 5 430 works)
--      S126804734   Appetite                          (12 791 works)
--      S21693283    Journal of Sensory Studies        ( 2 239 works)
--      S2898331414  Int. J. of Gastronomy and Food Sc ( 1 557 works)
--      S38919146    Food Research International       (19 152 works)
--      S2737939966  Foods                             (26 247 works)
--      S8722945     Chemical Senses                   ( 3 997 works)
insert into public.backfill_progress
  (source, identifier, direction, current_year, current_page, completed, last_run, total_fetched)
values
  ('openalex', 'S194662844',  'forward', 2026, 0, false, null, 0),
  ('openalex', 'S126804734',  'forward', 2026, 0, false, null, 0),
  ('openalex', 'S21693283',   'forward', 2026, 0, false, null, 0),
  ('openalex', 'S2898331414', 'forward', 2026, 0, false, null, 0),
  ('openalex', 'S38919146',   'forward', 2026, 0, false, null, 0),
  ('openalex', 'S2737939966', 'forward', 2026, 0, false, null, 0),
  ('openalex', 'S8722945',    'forward', 2026, 0, false, null, 0)
on conflict (source, identifier, direction) do nothing;


-- =============================================================================
-- Verifiering (efter apply):
--
--   -- 1. Direction-kolumnen finns på alla rader?
--   select direction, count(*) from public.backfill_progress
--    group by direction order by direction;
--   -- expected: backward=<antal existerande>, forward=7
--
--   -- 2. Appetite backward completed?
--   select identifier, direction, current_year, current_page, completed, total_fetched
--     from public.backfill_progress
--    where identifier = 'S126804734'
--    order by direction;
--   -- expected:
--   --   S126804734 backward 2016 2 true  <total>
--   --   S126804734 forward  2026 0 false 0
--
--   -- 3. Forward-jobben pickar upp vid nästa cron-tick?
--   select identifier, direction, current_year, current_page, last_run
--     from public.backfill_progress
--    where direction = 'forward'
--    order by last_run nulls first;
--   -- expected: 7 rader, alla last_run = null initialt; efter första
--   -- cron-körning: last_run satt, current_page eller current_year advancerat
--
--   -- 4. Unique constraint funkar för trippel?
--   insert into public.backfill_progress
--     (source, identifier, direction, current_year, current_page, completed, last_run, total_fetched)
--   values
--     ('openalex', 'S126804734', 'forward', 2026, 0, false, null, 0);
--   -- expected: unique violation (raden finns redan)
--
--   -- 5. Backward + forward för samma journal kan sameksistera?
--   select count(*) from public.backfill_progress
--    where identifier = 'S126804734';
--   -- expected: 2 (backward + forward)
--
--   -- 6. RPC-signatur uppdaterad?
--   select pg_get_functiondef(oid) from pg_proc
--    where proname = 'advance_backfill_progress';
--   -- expected: 7 params, p_direction med DEFAULT 'backward'
-- =============================================================================
