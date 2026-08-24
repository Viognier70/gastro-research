-- =============================================================================
-- ORDER 147 — apply topic-reklassificering av uncategorized, runda 4
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- ⚠️  KÖR RUNDA 4 (20260824130000_topic_keywords_round4.sql) FÖRST.
--    Den migrationen adderar 68 keywords som är nödvändiga för att denna
--    apply ska nå 3,447 movements. Utan round4 landar denna på baseline 2,256.
--
-- BAKGRUND (2026-08-24):
--
--   Dry-run scenario 'd' (keywords + title, min 2 hits OR (1 hit + kw_len ≥ 3))
--   efter round4-apply:
--
--     target_population: 7,574 (uncategorized non-irrelevant med keywords)
--     moved:             3,447 (45.5% av populationen)
--     unchanged:         4,127 (kvarstår som uncategorized)
--
--   Toppmottagare (delta):
--     food_science         +669
--     sommellerie          +610   ← mest från wine bare
--     food_anthropology    +587   ← traditional beverage(s), culinary history
--     fermentation_science +425   ← Lactobacillus/cheese ripening/fermented milk
--     sensory_evaluation   +331
--     flavor_science       +314
--     gastronomy           +251
--
--   Stickprov 200 rader (4 × sample=50, deduped) verifierade att alla
--   broad-kw-träffar (wine/cheese/milk/dairy/diet) landar rimligt: 31/10/7/3/1
--   rader vardera, ingen kardiologi, ingen medicinsk breastmilk, ingen
--   klinisk näringsepidemiologi. Wine → sommellerie, cheese/milk/dairy →
--   food_science, diet → nutritional_science. Detaljer i ORDER 147-svaret.
--
-- SKILLNAD MOT 20260806150000 (samma flöde, scenario A):
--
--   1. SCENARIO — den migrationen körde bara scenario A (keywords-only,
--      inget title-match). Denna kör scenario D (keywords + title, min 2
--      hits OR (1 hit + kw_len ≥ 3)) — samma logik som dry-run:en har
--      verifierat sample-vis.
--
--   2. AUDIT-LOG — den migrationen skrev UPDATE-changes utan spar. Denna
--      skriver ORIGINAL-topic per rad till public.topic_reclassify_log
--      FÖRST, så rollback är möjlig. 3,447 rader ändras, ingen väg tillbaka
--      annars.
--
--   3. RAPPORT — Deno-scriptet scripts/reclassify-report-round4.ts läser
--      log-tabellen och skriver Markdown-rapport till out/ (mönster från
--      batch-regen-sci.ts). Kör efter apply, INTE en del av denna migration.
--
-- TIDNING & TIMEOUT:
--
--   Scenario D dry-run (utan UPDATE) tog ~85s. Denna gör samma SCORING +
--   INSERT till log + UPDATE av 3,447 rader. Sannolikt 90-140s. SET LOCAL
--   statement_timeout = '30min' skyddar mot Postgres-sidan. SQL-editorn
--   använder direkt pg-connection (inte Envoy REST-proxy) så ~100s edge-
--   timeout från reclassify_dry_run-anropen gäller INTE här. Om det ändå
--   timeoutar: fallback är att köra samma via service-role via ett
--   Deno-script (mönster: scripts/reclassify-dry-run.ts).
--
-- SÄKERHET: BEGIN/COMMIT-block. Vid mid-transaction-fel rullas ALLT tillbaka
-- (både log-insert och article-update). Log-tabellen skapas med IF NOT
-- EXISTS så re-run är safe (fast idempotens är inte målet — batch_id
-- garanterar spårbarhet).
-- =============================================================================


begin;
set local statement_timeout = '30min';


-- ─── 1. AUDIT-LOG-TABELL (schema-safe) ──────────────────────────────────────
--
-- article_id refererar articles(id) med ON DELETE CASCADE — om artikeln
-- raderas ska loggen försvinna också. matched_kw är text[] med alla
-- keywords som orsakade tie-break-vinsten (samma format som
-- reclassify_dry_run.sample.matched).

create table if not exists public.topic_reclassify_log (
  id           bigserial primary key,
  article_id   uuid not null references public.articles(id) on delete cascade,
  old_topic    text not null,
  new_topic    text not null,
  matched_kw   text[] not null,
  batch_id     text not null,
  applied_at   timestamptz not null default now()
);

create index if not exists ix_topic_reclassify_log_batch
  on public.topic_reclassify_log(batch_id);
create index if not exists ix_topic_reclassify_log_article
  on public.topic_reclassify_log(article_id);

comment on table public.topic_reclassify_log is
  'ORDER 147: audit-log för topic-reklassificering. Rollback per batch: '
  'UPDATE articles SET topic = old_topic WHERE id IN '
  '(SELECT article_id FROM topic_reclassify_log WHERE batch_id = ?)';

-- service_role skriver, authenticated läser (för admin-verktyg)
grant select on public.topic_reclassify_log to authenticated, service_role;
grant insert on public.topic_reclassify_log to service_role;


-- ─── 2. BERÄKNA PICKS (matchar reclassify_dry_run scenario D exakt) ─────────
--
-- ON COMMIT DROP: temp-tabellen försvinner vid COMMIT — INSERT + UPDATE
-- nedan läser den innan dess.

create temp table _picks on commit drop as
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
)
select id, old_topic, new_topic, matched
from picks
where new_topic is not null
  and new_topic != old_topic;


-- ─── 3. SANITY: förvänta 3,447 (±5 för sedan-mätning-drift) ─────────────────

do $$ declare n int; begin
  select count(*) into n from _picks;
  raise notice 'ORDER 147 apply: % rader kommer att flyttas ur uncategorized (förväntat ~3447)', n;
  if n < 3000 or n > 4000 then
    raise warning 'ORDER 147: batch-size % avviker från dry-run 3447 — undersök innan commit', n;
  end if;
end $$;


-- ─── 4. INSERT till audit-log FÖRST ─────────────────────────────────────────

insert into public.topic_reclassify_log (article_id, old_topic, new_topic, matched_kw, batch_id)
select id, old_topic, new_topic, matched, 'ORDER-147-round4-uncategorized-2026-08-24'
from _picks;


-- ─── 5. UPDATE articles.topic ───────────────────────────────────────────────

update public.articles a
   set topic = p.new_topic
  from _picks p
 where a.id = p.id;


commit;


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Antal rader i audit-log för denna batch (målvärde ~3447):
--   select count(*) from public.topic_reclassify_log
--    where batch_id = 'ORDER-147-round4-uncategorized-2026-08-24';
--
--   -- 2. Ny topic-fördelning (jämför före-siffrorna i ORDER 147-svaret):
--   select topic, count(*) as n
--     from public.articles
--    where irrelevant is not true and topic is not null
--    group by topic
--    order by n desc;
--
--   -- 3. Kvar som uncategorized (förväntat ~4127):
--   select count(*) from public.articles
--    where topic = 'uncategorized' and irrelevant is not true;
--
--   -- 4. Refresh map-MV:er så dot-färger speglar nya ämnen:
--   select public.refresh_map_mvs();
--
--   -- 5. Skriv rapport till out/:
--   --      export SERVICE_ROLE_KEY=<key>
--   --      deno run --allow-net --allow-env --allow-write=out \
--   --        scripts/reclassify-report-round4.ts
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
--      and log.batch_id = 'ORDER-147-round4-uncategorized-2026-08-24'
--      and a.topic = log.new_topic;    -- guard: bara om värdet oförändrat sedan apply
--
--   -- Bekräfta rollback-summan matchar apply
--   select 'rollback: ' || count(*) || ' rader återställda'
--     from public.articles a
--     join public.topic_reclassify_log log on log.article_id = a.id
--    where log.batch_id = 'ORDER-147-round4-uncategorized-2026-08-24'
--      and a.topic = log.old_topic;
--
--   commit;
--
--   -- Refresh MV:er efter rollback
--   select public.refresh_map_mvs();
--
--   -- Ev. städa log-raderna (om rollback är permanent):
--   -- delete from public.topic_reclassify_log
--   --  where batch_id = 'ORDER-147-round4-uncategorized-2026-08-24';
-- =============================================================================
