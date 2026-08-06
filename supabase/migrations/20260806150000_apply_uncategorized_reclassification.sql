-- =============================================================================
-- Apply uncategorized reclassification — scenario A (keywords only, min 1)
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- ⚠️  KÖR DRY-RUN FÖRST och verifiera siffrorna innan denna körs. Populationen
--    är 7 519 (efter gastronomy-omklassningen 20260805200000), inte 2 135 som
--    vid mätningen som gav "målvärde 717". Många av de 5 384 nya
--    uncategorized-raderna kom dit för att INGET matchade — utfallet blir
--    sannolikt sämre än 717.
--
--    Kommando:
--      export SERVICE_ROLE_KEY=<key>
--      deno run --allow-net --allow-env scripts/reclassify-dry-run.ts \
--        --old-topic=uncategorized --only=a --sample=20
--
--    Titta på "moved" och "to_uncategorized" i outputen. Om "moved" är låg
--    relativt målpopulationen — överväg om apply är rätt beslut, eller om
--    fler keywords behövs i topic_keywords först.
--
-- BAKGRUND:
--
--   Ostartikeln 502e6dce har keywords med "sensory properties" och
--   "texture modification" — båda finns i topic_keywords sedan
--   round 2/3 (2026-08-05 rundorna). Den fick ändå uncategorized.
--
--   Förklaring: apply-migrationen 20260805200000 körde bara på
--   topic = 'gastronomy'. Uncategorized-populationen (7 519 rader efter
--   den migrationen) omklassades aldrig, så artiklar som skulle hamnat i
--   food_science / sensory_evaluation ligger kvar som uncategorized.
--
-- APPROACH: samma som 20260805200000 — SET LOCAL statement_timeout = '30min'
-- + UPDATE med LATERAL LIMIT 1 för argmax per artikel. Scenario A = keywords[]-
-- array only, min 1 hit. Ingen title-matching (som fällde REST-gatewayen
-- vid scenarier B/C/D i förra rundan).
--
-- SÄKERHET: BEGIN/COMMIT-block. Om något går sönder mitt-UPDATE → rullas
-- allt tillbaka.
--
-- EFTER APPLY:
--   1. Kör public.refresh_map_mvs() så map-vyerna speglar nya ämnen
--   2. Explore-vyn läser articles.topic direkt, ingen refresh behövs
-- =============================================================================

begin;
set local statement_timeout = '30min';

with picks as (
  select
    b.id,
    coalesce(argmax.topic, 'uncategorized') as new_topic
  from (
    select id, keywords
    from public.articles
    where topic = 'uncategorized'
      and keywords is not null
      and array_length(keywords, 1) > 0
      and irrelevant is not true
  ) b
  left join lateral (
    -- Argmax: topic med flest matchande keywords, ties → alfabetisk topic.
    -- Identiskt med 20260805200000; enda skillnaden är WHERE topic-filtret
    -- ovan (uncategorized istället för gastronomy).
    select tk.topic
    from public.topic_keywords tk
    join unnest(b.keywords) k(w) on lower(k.w) = lower(tk.keyword)
    group by tk.topic
    order by count(*) desc, tk.topic asc
    limit 1
  ) argmax on true
)
update public.articles a
   set topic = p.new_topic
  from picks p
 where a.id = p.id
   and a.topic != p.new_topic;    -- skip no-op-updates (winnare = 'uncategorized')

commit;


-- =============================================================================
-- Verifiering (kör som separata SELECTs efter apply):
--
--   -- 1. Ny topic-fördelning över hela corpus:
--   select topic, count(*) as n
--     from public.articles
--    where irrelevant is not true and topic is not null
--    group by topic
--    order by n desc;
--
--   -- 2. Kvar som uncategorized (hur många kunde inte matchas alls)?
--   select count(*) from public.articles
--    where topic = 'uncategorized' and irrelevant is not true;
--
--   -- 3. Sanity — ostartikeln 502e6dce ska nu ha ett meningsfullt topic:
--   select id, topic, keywords
--     from public.articles
--    where id::text like '502e6dce%';
--   -- expect: topic = food_science eller sensory_evaluation, inte uncategorized
--
--   -- 4. Slumpade nya rader per topic — verifiera att titeln matchar ämnet:
--   select topic, id, substring(title, 1, 100) as title
--     from public.articles
--    where irrelevant is not true and topic is not null
--    order by random() limit 30;
--
--   -- 5. Refresh map-MV:er så dot-färger speglar nya ämnen:
--   select public.refresh_map_mvs();
-- =============================================================================
