-- =============================================================================
-- ORDER 147 — topic_keywords runda 4 (2026-08-24)
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- BAKGRUND (2026-08-24):
--
--   ORDER 147-diagnos: 10,451 artiklar ligger som `topic = uncategorized`;
--   7,574 av dessa är non-irrelevant. Manuell genomgång av 100 slumpade
--   titlar (order=fetched_at.desc): ~93% skulle passa i något av de 27
--   existerande ämnena om keyword-listan täckte den korrekta domän-
--   vokabulären; ~4% är gastronomi-angränsande utanför nuvarande 27; ~3%
--   är genuint OT.
--
--   Dry-run baseline (scenario d, keywords+title, min 2 hits ELLER 1 hit
--   + ≥3 keywords totalt) före denna runda: 2,256 av 7,574 flyttas.
--   Kvarstår 5,318 rader som taxonomin inte når. Manuell genomgång pekade
--   på ~4,800 legit gastronomi-rader som saknar rätt substantivt keyword.
--
-- STRATEGI för runda 4 (additiv, ~66 nya keywords):
--
--   1. SUBSTANSTERMER som saknas — cheese/dairy/milk/wine/yogurt: bare
--      former som fångar dairy-tunga sampel-tunga journaler (Le Lait,
--      J. Dairy Sci., OENO One) och wine-forskning som fastnar utanför
--      "wine chemistry" / "wine tourism". False-positive-riskerna
--      dokumenterade per rad.
--
--   2. ORGANISM-NAMN — Lactobacillus, Lactococcus, Streptococcus
--      thermophilus, Bifidobacterium, Propionibacterium: snäva; fångar
--      fermentation-mikrobiologi som annars räknas 0 keyword-hits.
--
--   3. SUBSTRATE-FERMENTATION-KOMBINATIONER — fermented milk/meat/fish/
--      dairy: nuvarande dict har bara 'fermented food/foods/beverages'
--      + 'wine fermentation' + 'yeast fermentation' + 'kombucha
--      fermentation'.
--
--   4. FLAVOR/AROMA RELEASE-familjen — aroma release, flavor release,
--      volatile release, headspace/nosespace: extremt vanligt i J. Ag.
--      Food Chem., Le Lait, Chem. Senses — dagens dict fångar bara
--      'aroma compounds' / 'flavor perception' / 'olfaction food'.
--
--   5. USER-LISTADE (explicit specificerade i ORDER 147-svaret):
--      sommellerie: wine, winegrape, winegrapes, vineyard
--      sensory_evaluation: consumer acceptability, preference mapping,
--        taste threshold, detection threshold
--      nutritional_science/food_behavior: eating pattern, eating
--        behavior, dieting, diet
--      food_anthropology: traditional beverage, traditional
--        fermentation, culinary history
--      atmospherics/servicescape: restaurant environment, restaurant
--        lighting
--
-- FÖRE-DRY-RUN (scenario d, 2026-08-24 06:55Z):
--   uncategorized: 7574 → 5318 (2256 flyttade)
--   top-mottagare: food_anthropology +502, food_science +400,
--   sensory_evaluation +344, flavor_science +314, gastronomy +256
--
-- EFTER-DRY-RUN körs manuellt efter apply — jämför delta.
-- =============================================================================


insert into public.topic_keywords (topic, keyword) values

  -- ---------------------------------------------------------------------------
  -- fermentation_science — dairy/substrate/organisms
  -- ---------------------------------------------------------------------------
  ('fermentation_science', 'cheese ripening'),         -- 15+ hits i sampel; snäv
  ('fermentation_science', 'cheese microbiology'),
  ('fermentation_science', 'dairy fermentation'),
  ('fermentation_science', 'yogurt fermentation'),
  ('fermentation_science', 'yogurt'),                   -- bare; food context, låg FP-risk
  ('fermentation_science', 'yoghurt'),                  -- brit-stavning; samma
  ('fermentation_science', 'fermented milk'),
  ('fermentation_science', 'fermented meat'),
  ('fermentation_science', 'fermented fish'),
  ('fermentation_science', 'fermented dairy'),
  ('fermentation_science', 'lactic acid fermentation'),
  ('fermentation_science', 'lactobacillus'),           -- organism-namn, snäv
  ('fermentation_science', 'lactococcus'),
  ('fermentation_science', 'streptococcus thermophilus'), -- species-nivå, undviker "strep throat"-FP
  ('fermentation_science', 'bifidobacterium'),
  ('fermentation_science', 'propionibacterium'),
  ('fermentation_science', 'sake brewing'),
  ('fermentation_science', 'brewery'),
  ('fermentation_science', 'natto'),
  ('fermentation_science', 'miso'),
  ('fermentation_science', 'soy sauce'),
  ('fermentation_science', 'kombucha'),                 -- bare; runda 2 hade bara "kombucha fermentation"
  ('fermentation_science', 'bacteriocin'),

  -- ---------------------------------------------------------------------------
  -- flavor_science — release/delivery-familjen
  -- ---------------------------------------------------------------------------
  ('flavor_science', 'aroma release'),
  ('flavor_science', 'flavor release'),
  ('flavor_science', 'flavour release'),                -- brit-stavning
  ('flavor_science', 'volatile release'),
  ('flavor_science', 'aroma delivery'),
  ('flavor_science', 'headspace analysis'),
  ('flavor_science', 'nosespace'),
  ('flavor_science', 'cheese flavor'),
  ('flavor_science', 'cheese flavour'),
  ('flavor_science', 'dairy flavor'),
  ('flavor_science', 'wine flavor'),
  ('flavor_science', 'meat flavor'),

  -- ---------------------------------------------------------------------------
  -- food_science — dairy/cheese/milk-substans-fallback
  -- OBS: bare 'milk' / 'dairy' bär FP-risk för medicinsk breastmilk/
  -- laktos-intoleransforskning. Acceptabelt eftersom detectTopic:s
  -- max-score-tie-brytning oftast landar rätt när abstract innehåller
  -- flera food-keywords. Dry-run visar impact före skarp apply.
  -- ---------------------------------------------------------------------------
  ('food_science', 'cheese'),                          -- bare; sträcker sig över allt cheese
  ('food_science', 'dairy'),                           -- bare; RISK: breastmilk-forskning
  ('food_science', 'dairy product'),
  ('food_science', 'dairy science'),
  ('food_science', 'milk'),                            -- bare; RISK: samma, mildare
  ('food_science', 'milk protein'),
  ('food_science', 'milk fat'),
  ('food_science', 'meat processing'),
  ('food_science', 'meat quality'),

  -- ---------------------------------------------------------------------------
  -- sensory_evaluation — user-listade + threshold-familjen
  -- ---------------------------------------------------------------------------
  ('sensory_evaluation', 'consumer acceptability'),
  ('sensory_evaluation', 'preference mapping'),
  ('sensory_evaluation', 'taste threshold'),
  ('sensory_evaluation', 'detection threshold'),
  ('sensory_evaluation', 'sensory threshold'),
  ('sensory_evaluation', 'consumer preference'),        -- singular; runda 2 hade plural

  -- ---------------------------------------------------------------------------
  -- sommellerie — user-listade (wine bare = medveten valuing)
  -- OBS: 'wine' bare kommer matcha ALLT wine-relaterat inkl. bibliometri,
  -- konsumentbeteende och kardiovaskulär forskning. Sommellerie är
  -- rimlig topphink för de flesta, men "wine and your heart" (item 53 i
  -- sampel) landar sommellerie i st f nutritional_science. Trade-off:
  -- vi missar vs. felklassificerar — dry-run visar bidraget.
  -- ---------------------------------------------------------------------------
  ('sommellerie', 'wine'),
  ('sommellerie', 'winegrape'),
  ('sommellerie', 'winegrapes'),
  ('sommellerie', 'vineyard'),

  -- ---------------------------------------------------------------------------
  -- nutritional_science + food_behavior — user-listade
  -- OBS: 'diet' bare är extremt bred — matchar 'high-fat diet mouse
  -- model', 'ketogenic diet epilepsy trial' etc. Acceptabelt eftersom
  -- (a) irrelevance-check-lagret filtrerar bort merparten mus/klinik,
  -- (b) user explicit inkluderade det.
  -- ---------------------------------------------------------------------------
  ('nutritional_science', 'eating pattern'),
  ('nutritional_science', 'eating patterns'),          -- plural
  ('nutritional_science', 'eating behavior'),
  ('nutritional_science', 'dieting'),
  ('nutritional_science', 'diet'),                     -- bare; RISK: klinisk mus/human
  ('food_behavior', 'eating disorder'),
  ('food_behavior', 'eating behavior'),                -- dubblett per topic (tie-break-bidrag)

  -- ---------------------------------------------------------------------------
  -- food_anthropology — user-listade
  -- ---------------------------------------------------------------------------
  ('food_anthropology', 'traditional beverage'),
  ('food_anthropology', 'traditional beverages'),      -- plural
  ('food_anthropology', 'traditional fermentation'),
  ('food_anthropology', 'culinary history'),

  -- ---------------------------------------------------------------------------
  -- atmospherics / servicescape — user-listade
  -- ---------------------------------------------------------------------------
  ('atmospherics', 'restaurant environment'),
  ('atmospherics', 'restaurant lighting'),
  ('servicescape', 'servicescape design')

on conflict (topic, keyword) do nothing;


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Antal nya keywords per topic (jämför baseline i runda 3):
--   select topic, count(*) as n
--     from public.topic_keywords
--    group by topic
--    order by n desc;
--
--   -- 2. Kör dry-run scenario d och jämför mot baseline 2256 moved:
--   select public.reclassify_dry_run('uncategorized', 0, 'd');
--   -- expected: moved > 2256 (målnivå: 5000-6000 utifrån manuell analys)
--
--   -- 3. Om målnivå nås OCH fördelningen ser rimlig ut → separat migration
--   --    för skarp apply (mönster: 20260806150000_apply_uncategorized_
--   --    reclassification.sql). INGEN skarp apply i denna migration.
-- =============================================================================
