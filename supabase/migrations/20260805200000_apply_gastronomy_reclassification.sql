-- =============================================================================
-- Apply gastronomy reclassification — scenario A (keywords only, min 1)
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- Grundval för denna migration:
--
--   Dry-run scenario A (2026-08-05):
--     target_population: 18 131
--     moved:             17 629
--     to_uncategorized:   5 384
--     kvar som gastronomy: ~502 (12 245 fick meningsfullt ämne)
--
--   Scenario A = keywords[]-array only, min 1 hit. Title-matching (B/C/D)
--   nödvändig för perfekt fångst men fällde REST-gatewayen (130 s cap på
--   Supabase edge). A är dokumenterat safe: enkel exact-match mot keywords
--   som redan är destillerade termer från OpenAlex.
--
-- APPROACH:
--
--   Ett SET LOCAL statement_timeout = '30min' + en UPDATE med LATERAL LIMIT 1
--   för argmax per artikel. Scenario A-dry-run gick igenom i SQL-editorn utan
--   timeout så UPDATE med samma logik ska ha samma prestanda-profil.
--
--   Om det trots allt skulle timeouta: byt till batched-loop-pattern
--   (precompute till _reclass_tmp temp-table, uppdatera i batchar). Ej
--   inkluderat här eftersom scenario A redan visat sig gå igenom.
--
-- SÄKERHET: BEGIN/COMMIT-block så hela UPDATE:n är atomisk. Om något går
-- sönder mitt-UPDATE rullas allt tillbaka.
--
-- EFTER APPLY:
--   1. Kör refresh_map_mvs() så map-vyerna speglar nya ämnen
--      (dominant_topic per institution baseras på topic-count)
--   2. Verifiera Explore-vyn — knowledge_map_topics läser från articles.topic
--      direkt, ingen refresh behövs
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
    where topic = 'gastronomy'
      and keywords is not null
      and array_length(keywords, 1) > 0
      and irrelevant is not true
  ) b
  left join lateral (
    -- Argmax: topic med flest matchande keywords, ties → alfabetisk topic
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
   and a.topic != p.new_topic;    -- skip no-op-updates (winnare = 'gastronomy')

commit;


-- =============================================================================
-- Verifiering (kör som separata SELECTs efter apply):
--
--   -- 1. Ny topic-fördelning över hela corpus (jämför mot före):
--   select topic, count(*) as n
--     from public.articles
--    where irrelevant is not true and topic is not null
--    group by topic
--    order by n desc;
--
--   -- 2. Hur många gastronomy-rader kvar (målvärde: ~502 som var
--   --    "genuinly" gastronomy per keywords)?
--   select count(*) from public.articles
--    where topic = 'gastronomy' and irrelevant is not true;
--
--   -- 3. Hur många i uncategorized (delta bör vara ~+5 384)?
--   select count(*) from public.articles
--    where topic = 'uncategorized' and irrelevant is not true;
--
--   -- 4. Sanity — plocka slumpade rader i varje nu-nya kategori och
--   --    verifiera att titeln matchar ämnet:
--   select topic, id, substring(title, 1, 100) as title
--     from public.articles
--    where irrelevant is not true and topic is not null
--    order by random() limit 30;
--
--   -- 5. Kartans MV:er — refresh_map_mvs():
--   select public.refresh_map_mvs();  -- CONCURRENTLY så inte blockerar läsare
-- =============================================================================
