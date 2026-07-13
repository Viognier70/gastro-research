-- screening_funnel: konvertera från on-demand-vy till materialized view.
--
-- Bakgrund: den gamla vyn räknade 7 count-aggregater över hela articles
-- (456k rader) vid varje sidladdning. EXPLAIN visade 17,5 s exekvering
-- (full seq scan). PostgREST cap:as vid ~3-8 s → HTTP 500 med felkod
-- 57014 (canceling statement due to statement timeout) → frontend
-- sväljer tyst (`if(!r.ok) return`) → tratten står `hidden` för alla
-- besökare. Skalar inte till en användare, än mindre tio.
--
-- Fix: materialized view, refresh via pg_cron var 10:e min. Ingen
-- CONCURRENTLY (kräver unique-index och vinsten är liten här — vyn
-- är 1 rad, refresh på ~17 s med kort lås är acceptabelt när det
-- sker offline).
--
-- Säkerhet: matviews stöder inte RLS. Innehållet är enbart aggregat
-- (7 counts). Ingen radnivå-data, inga ID:n, inga texter. Grant till
-- anon+authenticated är säkert.
--
-- Ingen kolumnändring vs föregående vy — frontend FUNNEL_STEPS läser
-- samma nycklar (indexerade, unika_doi, med_abstract, screenade,
-- relevanta, triad_analyserade). med_imrad exponeras kvar för
-- framtida bruk.

drop view if exists public.screening_funnel;

create materialized view public.screening_funnel as
select
  count(*) as indexerade,
  count(distinct nullif(regexp_replace(url, '.*doi\.org/', ''), ''))
    filter (where url ilike '%doi.org%') as unika_doi,
  count(*) filter (where abstract is not null
                     and length(trim(abstract)) >= 100) as med_abstract,
  count(*) filter (where relevance_checked = true) as screenade,
  count(*) filter (where relevance_checked = true and irrelevant = false) as relevanta,
  count(*) filter (where imrad_methods is not null) as med_imrad,
  count(*) filter (where phronesis_educator_researcher is not null) as triad_analyserade
from public.articles;

-- Supabase default alter default privileges ger anon+authenticated en bred
-- uppsättning rättigheter (arwdDxtm) på nya relationer. Matviews är read-only
-- så INSERT/UPDATE/DELETE är effektivt no-op, men MAINTAIN (m, PG17+) skulle
-- låta anon köra REFRESH → DoS via ~17s exekvering per anrop. Lås ned till
-- ren SELECT.
revoke all on public.screening_funnel from anon, authenticated;
grant select on public.screening_funnel to anon, authenticated;

-- Cron-schemat (Anders kör separat via SQL editor efter denna migration):
--   select cron.schedule(
--     'refresh-screening-funnel',
--     '*/10 * * * *',
--     $CRON$ refresh materialized view public.screening_funnel $CRON$
--   );
-- Namngiven dollar-tagg för att undvika konflikt med extern quoting.
