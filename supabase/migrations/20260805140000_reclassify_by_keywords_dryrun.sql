-- =============================================================================
-- Ämnesomklassificering baserad på keywords[] — dry-run 2026-08-05
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- BAKGRUND:
--
--   18 137 artiklar bär topic='gastronomy' i DB. Analys 2026-08-05 visade
--   att dessa är LEGACY från före commit 6dbd625 (2026-07-09) — då var
--   'gastronomy' default för artiklar som inte träffade någon TOPICS-nyckel.
--   Detta skickade sensorik-, fermentation-, smakkemi- och konsument-litteratur
--   till gastronomy-topic'en.
--
--   99.97 % (18 131 av 18 137) av dessa har populerad keywords[]-array
--   från OpenAlex. Nyckelorden är redan destillerade termer (concepts +
--   raw keywords från OA), så matchning mot keywords[] är strängare och
--   mer träffsäker än detectTopic:s title+abstract+journal-scan.
--
-- DENNA MIGRATION LEVERERAR ENDAST DRY-RUN:
--
--   Inga UPDATE på articles.topic. Två RPC:er:
--     1. score_topics(text[]) → set-returning helper (per-topic scores)
--     2. reclassify_dry_run(old_topic, sample_n) → JSONB med:
--        - distribution: {topic, before, after, delta} för hela corpusen
--        - sample: N slumpade artiklar med title + old/new_topic + matched
--
--   När fördelningen ser rimlig ut byggs en separat migration som
--   applicerar UPDATE-en, samt (troligen) syncar daily-fetch:s JS-TOPICS-
--   dict med topic_keywords-tabellen så framtida ingest matchar samma
--   klassificering.
--
-- TABELL topic_keywords SOM KÄLLA TILL SANNING:
--
--   Nuvarande TOPICS lever hårdkodat i daily-fetch/index.ts:85-112. Att
--   spegla den i en DB-tabell tillåter SQL-baserad omklassificering + gör
--   framtida sync möjlig (endera daily-fetch läser från tabellen, eller
--   vi håller båda i sync med en checklista). Väljs medvetet framför att
--   inline:a keyword-arrays i RPC:n — då kan additionerna itereras utan
--   migration-omkörning (INSERT vs CREATE OR REPLACE FUNCTION).
-- =============================================================================

-- 1. Tabell + seed
create table if not exists public.topic_keywords (
  topic   text not null,
  keyword text not null,
  primary key (topic, keyword)
);

-- Tomma innan re-seed så tillägg tas i beaktning även vid ny körning.
truncate public.topic_keywords;

insert into public.topic_keywords (topic, keyword) values
  -- EXISTERANDE (från daily-fetch:85-112, oförändrade)
  ('sommellerie', 'sommelier'),
  ('sommellerie', 'wine tasting'),
  ('sommellerie', 'wine evaluation'),
  ('sommellerie', 'oenology'),
  ('sommellerie', 'wine sensory'),
  ('sommellerie', 'viticulture'),

  ('gastronomy', 'gastronomy'),
  ('gastronomy', 'haute cuisine'),
  ('gastronomy', 'culinary arts'),
  ('gastronomy', 'fine dining'),
  ('gastronomy', 'gourmet'),
  -- gastronomy TILLÄGG 2026-08-05: bara termer som faktiskt är gastronomi
  ('gastronomy', 'culinary tourism'),
  ('gastronomy', 'culinary heritage'),
  ('gastronomy', 'destination marketing'),
  ('gastronomy', 'food tourism'),
  ('gastronomy', 'gastronomy tourism'),

  ('multisensory', 'multisensory'),
  ('multisensory', 'crossmodal'),
  ('multisensory', 'sensory integration'),
  ('multisensory', 'multimodal'),

  ('culinary_science', 'culinary science'),
  ('culinary_science', 'cooking science'),
  ('culinary_science', 'culinary chemistry'),

  ('food_science', 'food science'),
  ('food_science', 'food technology'),
  ('food_science', 'food processing'),
  -- food_science TILLÄGG 2026-08-05: OBS breda termer. Om senare visar sig
  -- dra in för mycket kan food_safety/food_preservation brytas ut som egna
  -- topics. 5-familjslegenden har idag ingen safety-plats så det motiverade
  -- inte ny topic vid införandet.
  ('food_science', 'food safety'),
  ('food_science', 'food preservation'),
  ('food_science', 'food quality'),
  ('food_science', 'shelf life'),
  ('food_science', 'food storage'),

  ('flavor_science', 'food flavor'),
  ('flavor_science', 'food flavour'),
  ('flavor_science', 'taste perception food'),
  ('flavor_science', 'olfaction food'),
  ('flavor_science', 'food aroma'),
  ('flavor_science', 'retronasal olfaction'),
  -- flavor_science TILLÄGG 2026-08-05: både amerikansk och brittisk stavning
  -- eftersom OpenAlex-keywords inte normaliserar mellan dem.
  ('flavor_science', 'volatile compounds'),
  ('flavor_science', 'aroma compounds'),
  ('flavor_science', 'flavor compounds'),
  ('flavor_science', 'flavour compounds'),
  ('flavor_science', 'flavor chemistry'),
  ('flavor_science', 'flavour chemistry'),
  ('flavor_science', 'flavor development'),
  ('flavor_science', 'flavor perception'),

  ('sensory_evaluation', 'sensory evaluation'),
  ('sensory_evaluation', 'sensory panel'),
  ('sensory_evaluation', 'sensory analysis'),
  -- sensory_evaluation TILLÄGG 2026-08-05: alla "sensory X" är otvetydiga;
  -- descriptive analysis är QDA-teknik-benämning.
  ('sensory_evaluation', 'sensory profiling'),
  ('sensory_evaluation', 'sensory perception'),
  ('sensory_evaluation', 'sensory quality'),
  ('sensory_evaluation', 'sensory properties'),
  ('sensory_evaluation', 'sensory attributes'),
  ('sensory_evaluation', 'sensory characteristics'),
  ('sensory_evaluation', 'descriptive analysis'),

  ('food_psychology', 'food psychology'),
  ('food_psychology', 'eating behavior'),
  ('food_psychology', 'food choice'),
  ('food_psychology', 'food preference'),
  -- food_psychology TILLÄGG 2026-08-05: consumer X-varianterna. Fristående
  -- "perception" avsiktligt EJ tillagd — matchar sensory/crossmodal/etc utan
  -- att särskilja.
  ('food_psychology', 'consumer behavior'),
  ('food_psychology', 'consumer acceptance'),
  ('food_psychology', 'consumer preference'),

  ('neurogastronomy', 'neurogastronomy'),
  ('neurogastronomy', 'neuroculinary'),
  ('neurogastronomy', 'brain taste'),
  ('neurogastronomy', 'flavor neuroscience'),

  ('food_anthropology', 'food anthropology'),
  ('food_anthropology', 'food culture'),
  ('food_anthropology', 'food identity'),
  ('food_anthropology', 'culinary tradition'),

  ('atmospherics', 'atmospherics'),
  ('atmospherics', 'ambient'),
  ('atmospherics', 'restaurant environment'),
  ('atmospherics', 'dining atmosphere'),

  ('hospitality', 'hospitality'),
  ('hospitality', 'service quality'),
  ('hospitality', 'guest experience'),
  ('hospitality', 'hotel management'),

  ('servicescape', 'servicescape'),
  ('servicescape', 'physical environment service'),

  ('experiential_dining', 'experiential dining'),
  ('experiential_dining', 'immersive dining'),
  ('experiential_dining', 'themed restaurant'),

  ('nutritional_science', 'nutritional science'),
  ('nutritional_science', 'nutrition'),
  ('nutritional_science', 'dietary'),
  ('nutritional_science', 'macronutrient'),

  ('food_behavior', 'food behavior'),
  ('food_behavior', 'eating habits'),
  ('food_behavior', 'dietary behavior'),
  ('food_behavior', 'food intake'),

  ('appetite_research', 'appetite'),
  ('appetite_research', 'hunger'),
  ('appetite_research', 'satiety'),
  ('appetite_research', 'satiation'),
  ('appetite_research', 'food reward'),

  ('food_technology', 'food technology'),
  ('food_technology', 'food innovation'),
  ('food_technology', 'novel processing'),

  ('fermentation_science', 'fermentation'),
  ('fermentation_science', 'fermented food'),
  ('fermentation_science', 'probiotic'),
  ('fermentation_science', 'koji'),
  -- fermentation_science TILLÄGG 2026-08-05
  ('fermentation_science', 'lactic acid bacteria'),
  ('fermentation_science', 'saccharomyces cerevisiae'),
  ('fermentation_science', 'starter cultures'),
  ('fermentation_science', 'yeast fermentation'),
  ('fermentation_science', 'fermented beverages'),

  ('food_pairing', 'food pairing'),
  ('food_pairing', 'flavor pairing'),
  ('food_pairing', 'wine pairing'),

  ('molecular_mixology', 'molecular mixology'),
  ('molecular_mixology', 'molecular gastronomy'),
  ('molecular_mixology', 'spherification'),

  ('culinary_education', 'culinary education'),
  ('culinary_education', 'chef training'),
  ('culinary_education', 'culinary school'),

  ('sensory_training', 'sensory training'),
  ('sensory_training', 'taste training'),
  ('sensory_training', 'olfactory training'),

  ('novel_foods', 'novel foods'),
  ('novel_foods', 'insect protein'),
  ('novel_foods', 'lab-grown meat'),
  ('novel_foods', 'plant-based meat'),

  ('crossmodal', 'crossmodal'),
  ('crossmodal', 'cross-modal'),
  ('crossmodal', 'sound taste'),
  ('crossmodal', 'music food'),
  ('crossmodal', 'color taste'),

  ('art_science', 'food design'),
  ('art_science', 'plating aesthetics'),
  ('art_science', 'food aesthetics'),
  ('art_science', 'culinary art')
;

create index if not exists idx_topic_keywords_kw_lower
  on public.topic_keywords (lower(keyword));


-- 2. Hjälpfunktion — poäng per topic för en keyword-array
create or replace function public.score_topics(p_keywords text[])
returns table(topic text, matched text[], score int)
language sql
stable
as $function$
  select
    tk.topic,
    array_agg(distinct lower(kw.word)) as matched,
    count(distinct tk.keyword)::int as score
  from unnest(p_keywords) as kw(word)
  join public.topic_keywords tk
    on lower(tk.keyword) = lower(kw.word)
  group by tk.topic
$function$;


-- 3. Dry-run RPC — returnerar JSONB med distribution + sample
--
-- Kör: select public.reclassify_dry_run('gastronomy', 200);
--
-- Distribution innehåller ALLA topics där before eller after är non-zero.
-- Sample innehåller N slumpade artiklar där new_topic != old_topic.
-- Sample_n = 0 → tom sample-array (bara distribution).
create or replace function public.reclassify_dry_run(
  p_old_topic text,
  p_sample_n  int default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  v_result jsonb;
begin
  with candidates as (
    -- Alla artiklar i target-populationen + föreslagen ny topic + matched keywords.
    -- LEFT JOIN LATERAL för att fånga "0 matches → uncategorized"-fallet.
    select
      a.id,
      a.title,
      a.topic as old_topic,
      a.keywords,
      coalesce(c.topic, 'uncategorized') as new_topic,
      coalesce(c.matched, array[]::text[]) as matched
    from public.articles a
    left join lateral (
      select st.topic, st.matched
      from public.score_topics(a.keywords) st
      order by st.score desc, st.topic
      limit 1
    ) c on true
    where a.topic = p_old_topic
      and a.keywords is not null
      and array_length(a.keywords, 1) > 0
      and a.irrelevant is not true
  ),
  before_dist as (
    -- Aktuell topic-fördelning över hela corpusen (non-irrelevant).
    select topic, count(*)::int as c
    from public.articles
    where irrelevant is not true
      and topic is not null
    group by topic
  ),
  moved as (
    -- Delta: hur många artiklar LÄMNAR old_topic → hur många LANDAR på new_topic.
    select new_topic as topic, count(*)::int as inflow
    from candidates
    where new_topic != old_topic
    group by new_topic
  ),
  moved_out as (
    -- Från old_topic försvinner exakt så många som byter topic.
    select p_old_topic as topic, count(*)::int as outflow
    from candidates
    where new_topic != old_topic
  ),
  after_dist as (
    select
      coalesce(b.topic, m.topic) as topic,
      coalesce(b.c, 0)
        + coalesce(m.inflow, 0)
        - case when coalesce(b.topic, m.topic) = p_old_topic
               then (select outflow from moved_out)
               else 0 end as c
    from before_dist b
    full outer join moved m on b.topic = m.topic
  ),
  distribution as (
    select
      coalesce(a.topic, b.topic) as topic,
      coalesce(b.c, 0) as before,
      coalesce(a.c, 0) as after,
      coalesce(a.c, 0) - coalesce(b.c, 0) as delta
    from before_dist b
    full outer join after_dist a on a.topic = b.topic
    where coalesce(a.c, 0) > 0 or coalesce(b.c, 0) > 0
    order by abs(coalesce(a.c, 0) - coalesce(b.c, 0)) desc
  ),
  sample as (
    select
      id,
      substring(title, 1, 140) as title,
      old_topic,
      new_topic,
      matched
    from candidates
    where new_topic != old_topic
    order by random()
    limit greatest(p_sample_n, 0)
  )
  select jsonb_build_object(
    'target_population', (select count(*) from candidates),
    'moved',             (select count(*) from candidates where new_topic != old_topic),
    'unchanged',         (select count(*) from candidates where new_topic = old_topic),
    'distribution',      coalesce((select jsonb_agg(row_to_json(d)) from distribution d), '[]'::jsonb),
    'sample',            coalesce((select jsonb_agg(row_to_json(s)) from sample s), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$function$;


-- 4. Grants — admin-operation. score_topics är stateless och kan ges bredare
-- om det behövs senare; för nu bara service_role på båda.
revoke all on function public.score_topics(text[]) from public;
grant execute on function public.score_topics(text[]) to service_role;

revoke all on function public.reclassify_dry_run(text, int) from public;
grant execute on function public.reclassify_dry_run(text, int) to service_role;

revoke all on table public.topic_keywords from anon, authenticated;
grant select, insert, update, delete on public.topic_keywords to service_role;


-- =============================================================================
-- Användning (i SQL-editorn):
--
--   -- Fördelning + 200 sample-rader:
--   select public.reclassify_dry_run('gastronomy', 200);
--
--   -- Bara fördelning (utan sample):
--   select public.reclassify_dry_run('gastronomy', 0);
--
--   -- Läsa fördelningen tabelliserat:
--   select
--     value->>'topic' as topic,
--     (value->>'before')::int as before,
--     (value->>'after')::int as after,
--     (value->>'delta')::int as delta
--   from jsonb_array_elements(
--     (public.reclassify_dry_run('gastronomy', 0))->'distribution'
--   )
--   order by delta;
--
--   -- Läsa sample:
--   select
--     value->>'title' as title,
--     value->>'old_topic' as old,
--     value->>'new_topic' as new,
--     value->'matched' as matched
--   from jsonb_array_elements(
--     (public.reclassify_dry_run('gastronomy', 20))->'sample'
--   );
--
-- Efter godkänd dry-run kommer separat migration som gör UPDATE-en +
-- eventuellt syncar daily-fetch:s JS-TOPICS-dict.
-- =============================================================================
