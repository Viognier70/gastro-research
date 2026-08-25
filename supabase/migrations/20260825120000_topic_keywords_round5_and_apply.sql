-- =============================================================================
-- ORDER 152 — topic_keywords runda 5 + apply mot uncategorized-residualen
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- BAKGRUND (2026-08-25):
--
--   ORDER 147-apply flyttade 3,448 av 7,574 uncategorized non-irrelevant
--   ur uncategorized-hinken. Kvar: 4,135 rader (var 4,127 vid apply; +8
--   pipeline-inflow senaste dygnet).
--
--   ORDER 152-diagnos av residualen visade: alla 4,135 har keywords
--   (mean 16 kw/rad), men keywords är OpenAlex-meta-vokabulär i det
--   HÖGRE konceptlagret ('Culinary Culture and Tourism', 'Food History',
--   'Cultural Heritage' etc.) som vår topic_keywords-lista aldrig
--   inkluderat. Formuleringsproblem, inte att materialet är off-topic.
--
--   Frekvenstabell över uncat-populationen bekräftade elva entydiga
--   OpenAlex-meta-kandidater. 'wine industry and tourism' (28 kw-träffar)
--   uteslöts från listan — de flesta 7 rader som skulle flyttats till
--   sommellerie förlorar tie-break mot andra topics ändå.
--
-- STRATEGI för runda 5:
--
--   Elva keywords, tre topics — additivt (ON CONFLICT DO NOTHING),
--   omedelbart följt av apply mot uncategorized-populationen i SAMMA
--   transaktion. Skillnad mot ORDER 147 som splittade i två migrationer:
--   runda 5 är liten (11 kw, 416 movements) och de proposed keywords
--   används INTE av någon annan population än uncategorized (verifierat
--   i dry-run — inga false-positive-flyttar från andra topics), så en-
--   fils-flödet är säkert.
--
-- REV 2 (2026-08-25): rev 1 använde `CREATE TEMP TABLE _picks ON COMMIT DROP`
--   men Supabase SQL-editorn splittar transaktionen mellan satser så
--   temp-tabellen försvann före apply-UPDATE ("_picks does not exist").
--   Rev 2 använder Postgres-mönstret `WITH ... INSERT ... RETURNING`
--   följt av UPDATE FROM logged — allt i EN sats så inga temporära
--   objekt behöver överleva mellan editor-satser.
--
-- DRY-RUN-BEVIS (torrkörning 2026-08-25, före apply):
--   Total flyttar:        416 av 4,135 (10.1%)
--   food_anthropology:    311 (culinary culture and tourism dominerar med 189)
--   culinary_science:     70  (sustainable ingredients + ingredient sourcing/substitution)
--   food_psychology:      35  (sentiment analysis)
--   Kvar i uncategorized: 3,719 (49% av ORDER 147:s ursprungliga 7,574)
--
-- EFTER RUNDA 5:
--   3,871 av 7,574 flyttade sammanlagt över runderna 4+5 (51.1%).
--   Kvar 3,719 rader kräver AI-spår (Haiku/Sonnet topic-classify) —
--   utanför scope här; se ORDER 152:s nästa iteration.
-- =============================================================================


begin;
set local statement_timeout = '30min';


-- ─── 1. LÄGG TILL 11 NYA KEYWORDS ───────────────────────────────────────────
--
-- topic_reclassify_log skapades i ORDER 147-migrationen 20260824140000 och
-- återanvänds här. Se rollback-blocket i slutet av denna fil.

insert into public.topic_keywords (topic, keyword) values

  -- food_anthropology — 7 keywords från OpenAlex kultur-vokabulär
  ('food_anthropology', 'culinary culture and tourism'),  -- 189 träffar (dominant)
  ('food_anthropology', 'food history'),                   -- 38
  ('food_anthropology', 'cultural heritage'),              -- 36
  ('food_anthropology', 'cultural gastronomy'),            -- 31
  ('food_anthropology', 'cultural preservation'),          -- 27
  ('food_anthropology', 'food heritage'),                  -- 26
  ('food_anthropology', 'culinary traditions'),            -- 24 (plural; runda 1 hade singular)

  -- food_psychology — 1 keyword
  ('food_psychology', 'sentiment analysis'),               -- 35

  -- culinary_science — 3 keywords
  ('culinary_science', 'sustainable ingredients'),         -- 24
  ('culinary_science', 'ingredient substitution'),         -- 23
  ('culinary_science', 'ingredient sourcing')              -- 23

on conflict (topic, keyword) do nothing;


-- ─── 2. APPLY: EN SATS med data-modifying CTE-kedja ─────────────────────────
--
-- Postgres tillåter INSERT/UPDATE/DELETE inne i WITH-clauses. Alla CTE:er
-- exekverar mot samma snapshot vid sats-start:
--   1. base → scored → ranked → picks → final: matchar reclassify_dry_run
--      scenario D exakt (kw+title, min 2 hits ELLER 1 hit + kw_len ≥ 3)
--   2. logged: INSERT till topic_reclassify_log, RETURNING (article_id, new_topic)
--   3. Yttre UPDATE: läser logged och skriver articles.topic
--
-- Ordning garanterad: data-modifying CTE:er kör i sin helhet innan yttre
-- statement börjar läsa deras output. Ingen temp-tabell behövs.
--
-- topic_keywords-INSERTen ovan är synlig här — samma transaktion.

with base as (
  select id, title, topic as old_topic, keywords,
         coalesce(array_length(keywords, 1), 0) as kw_len
  from public.articles
  where topic = 'uncategorized'
    and keywords is not null
    and array_length(keywords, 1) > 0
    and irrelevant is not true
),
scored as (
  select
    b.id, b.old_topic, b.kw_len, tk.topic,
    count(*) filter (
      where exists (select 1 from unnest(b.keywords) as k(w) where lower(k.w) = lower(tk.keyword))
         or (b.title is not null and position(lower(tk.keyword) in lower(b.title)) > 0)
    )::int as kw_title_score,
    array_agg(distinct lower(tk.keyword)) filter (
      where exists (select 1 from unnest(b.keywords) as k(w) where lower(k.w) = lower(tk.keyword))
         or (b.title is not null and position(lower(tk.keyword) in lower(b.title)) > 0)
    ) as matched
  from base b
  cross join public.topic_keywords tk
  group by b.id, b.old_topic, b.kw_len, tk.topic
  having count(*) filter (
    where exists (select 1 from unnest(b.keywords) as k(w) where lower(k.w) = lower(tk.keyword))
       or (b.title is not null and position(lower(tk.keyword) in lower(b.title)) > 0)
  ) > 0
),
ranked as (
  select s.*,
         row_number() over (partition by s.id order by s.kw_title_score desc, s.topic asc) as rn
  from scored s
),
picks as (
  select
    b.id, b.old_topic, b.kw_len,
    max(case when r.rn = 1
              and (r.kw_title_score >= 2
                   or (r.kw_title_score = 1 and b.kw_len >= 3))
             then r.topic end) as new_topic,
    max(case when r.rn = 1
              and (r.kw_title_score >= 2
                   or (r.kw_title_score = 1 and b.kw_len >= 3))
             then r.matched end) as matched
  from base b
  left join ranked r on r.id = b.id
  group by b.id, b.old_topic, b.kw_len
),
final as (
  select id, old_topic, new_topic, matched
  from picks
  where new_topic is not null
    and new_topic != old_topic
),
logged as (
  insert into public.topic_reclassify_log (article_id, old_topic, new_topic, matched_kw, batch_id)
  select id, old_topic, new_topic, matched, 'ORDER-152-round5-uncategorized-2026-08-25'
  from final
  returning article_id, new_topic
)
update public.articles a
   set topic = l.new_topic
  from logged l
 where a.id = l.article_id;


-- ─── 3. SANITY: läs actual batch-count från log (fortfarande i tx) ──────────
--
-- Målvärde 416 ±5% enligt dry-run. Om avvikelse: WARNING syns i SQL-editorns
-- notice-panel, men transaktionen commit:ar ändå — det är en informationell
-- flagga för operatören, inte en abort-trigger.

do $$ declare n int; begin
  select count(*) into n from public.topic_reclassify_log
   where batch_id = 'ORDER-152-round5-uncategorized-2026-08-25';
  raise notice 'ORDER 152 apply: % rader loggade och flyttade (förväntat ~416)', n;
  if n < 350 or n > 500 then
    raise warning 'ORDER 152: batch-size % avviker från dry-run 416 — undersök innan produktions-tests', n;
  end if;
end $$;


commit;


-- =============================================================================
-- VERIFIERING EFTER APPLY (kör separat efter commit):
--
--   -- 1. Antal rader i audit-log för denna batch (målvärde ~416):
--   select count(*) from public.topic_reclassify_log
--    where batch_id = 'ORDER-152-round5-uncategorized-2026-08-25';
--
--   -- 2. Fördelning per target-topic (jämför mot dry-run):
--   select new_topic, count(*) as n
--     from public.topic_reclassify_log
--    where batch_id = 'ORDER-152-round5-uncategorized-2026-08-25'
--    group by new_topic
--    order by n desc;
--   -- expected: food_anthropology ~311, culinary_science ~70, food_psychology ~35
--
--   -- 3. Kvar som uncategorized (förväntat ~3719):
--   select count(*) from public.articles
--    where topic = 'uncategorized' and irrelevant is not true;
--
--   -- 4. Refresh map-MV:er så dot-färger speglar nya ämnen:
--   select public.refresh_map_mvs();
-- =============================================================================


-- =============================================================================
-- ROLLBACK (om något visar sig fel efteråt):
--
--   begin;
--   set local statement_timeout = '10min';
--
--   update public.articles a
--      set topic = log.old_topic
--     from public.topic_reclassify_log log
--    where log.article_id = a.id
--      and log.batch_id = 'ORDER-152-round5-uncategorized-2026-08-25'
--      and a.topic = log.new_topic;    -- guard: bara om värdet oförändrat sedan apply
--
--   -- Bekräfta rollback-summan matchar apply
--   select 'rollback: ' || count(*) || ' rader återställda'
--     from public.articles a
--     join public.topic_reclassify_log log on log.article_id = a.id
--    where log.batch_id = 'ORDER-152-round5-uncategorized-2026-08-25'
--      and a.topic = log.old_topic;
--
--   commit;
--
--   -- Refresh MV:er efter rollback
--   select public.refresh_map_mvs();
--
--   -- Om även keyword-tillägget ska rullas tillbaka:
--   -- delete from public.topic_keywords
--   --  where (topic, keyword) in (
--   --    ('food_anthropology', 'culinary culture and tourism'),
--   --    ('food_anthropology', 'food history'),
--   --    ('food_anthropology', 'cultural heritage'),
--   --    ('food_anthropology', 'cultural gastronomy'),
--   --    ('food_anthropology', 'cultural preservation'),
--   --    ('food_anthropology', 'food heritage'),
--   --    ('food_anthropology', 'culinary traditions'),
--   --    ('food_psychology',   'sentiment analysis'),
--   --    ('culinary_science',  'sustainable ingredients'),
--   --    ('culinary_science',  'ingredient substitution'),
--   --    ('culinary_science',  'ingredient sourcing')
--   --  );
--
--   -- Ev. städa log-raderna (om rollback är permanent):
--   -- delete from public.topic_reclassify_log
--   --  where batch_id = 'ORDER-152-round5-uncategorized-2026-08-25';
-- =============================================================================
