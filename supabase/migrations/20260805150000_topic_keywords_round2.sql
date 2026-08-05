-- =============================================================================
-- topic_keywords — runda 2 av tillägg (2026-08-05)
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- Runda 2 bygger på observationer från runda 1:s dry-run + top-40-analys
-- av keywords bland uncategorized-fickan. Enbart additioner via INSERT
-- ... ON CONFLICT DO NOTHING så git-diff visar exakt vad denna runda
-- lade till (jfr TRUNCATE + full re-seed i 20260805140000).
--
-- Antal nya keywords: 34. Total växer från ~155 → ~189, fortfarande
-- 26 topics.
--
-- BESLUT PÅ FYRA OSÄKRA (2026-08-05):
--   * product development (172)      → food_science
--   * sustainability (83)            → SKIPPA (för brett, matchar ESG/klimat/turism)
--   * nutritional fortification (65) → nutritional_science
--   * food waste reduction (53)      → food_science
--   * physicochemical properties (111) → food_science (överklockad från runda 1;
--                                        false-positive-risken lägre i praktik)
-- =============================================================================

insert into public.topic_keywords (topic, keyword) values

  -- sensory_evaluation — 5 varianter
  ('sensory_evaluation', 'sensory science'),
  ('sensory_evaluation', 'sensory profile'),          -- singular; runda 1 hade 'sensory profiling'
  ('sensory_evaluation', 'sensory chemistry'),
  ('sensory_evaluation', 'sensory acceptability'),
  ('sensory_evaluation', 'taste perception'),          -- runda 1 hade 'taste perception food'; generisk variant

  -- fermentation_science — 4 varianter, alla mikrobiologi-anknutna
  ('fermentation_science', 'fermentation microbiology'),
  ('fermentation_science', 'kombucha fermentation'),
  ('fermentation_science', 'microbial fermentation'),
  ('fermentation_science', 'food microbiology'),

  -- flavor_science — 3 varianter
  ('flavor_science', 'volatile organic compounds'),
  ('flavor_science', 'flavor profiling'),
  ('flavor_science', 'wine chemistry'),                -- analytical, skiljs från sommellerie (tasting)

  -- food_science — 14 tillägg, största utökningen. OBS breda termer;
  -- bevaka i uppföljande dry-run om t.ex. metabolomics drar in oönskade
  -- rader från cellbiologi (avsikt: livsmedels-metabolomik).
  ('food_science', 'shelf life extension'),
  ('food_science', 'physicochemical properties'),      -- överklockad från runda 1
  ('food_science', 'rheological properties'),
  ('food_science', 'texture optimization'),
  ('food_science', 'texture modification'),
  ('food_science', 'quality control'),
  ('food_science', 'chemical composition'),
  ('food_science', 'functional foods'),
  ('food_science', 'functional ingredients'),
  ('food_science', 'bioactive compounds'),
  ('food_science', 'antioxidant activity'),
  ('food_science', 'phenolic compounds'),
  ('food_science', 'metabolomics'),
  ('food_science', 'product development'),             -- rundade osäkra: R&D-fickan
  ('food_science', 'food waste reduction'),            -- rundade osäkra: food-system operations

  -- food_psychology — 4 tillägg, consumer/customer-varianter
  ('food_psychology', 'consumer perception'),
  ('food_psychology', 'consumer preferences'),         -- plural; runda 1 hade singular
  ('food_psychology', 'customer satisfaction'),
  ('food_psychology', 'customer experience'),

  -- hospitality — 2 tillägg
  ('hospitality', 'hospitality management'),
  ('hospitality', 'restaurant operations'),

  -- sommellerie — 2 tillägg
  ('sommellerie', 'wine quality'),
  ('sommellerie', 'terroir'),

  -- gastronomy — 2 tillägg
  ('gastronomy', 'wine tourism'),
  ('gastronomy', 'gastronomic tourism'),

  -- nutritional_science — 1 tillägg
  ('nutritional_science', 'nutritional fortification')

on conflict (topic, keyword) do nothing;


-- =============================================================================
-- Verifiering (efter apply):
--
--   -- Bekräfta antal keywords per topic (jämför runda 1-baseline):
--   select topic, count(*) as n
--     from public.topic_keywords
--    group by topic
--    order by n desc;
--
--   -- Kör dry-run igen och jämför mot runda 1:
--   select public.reclassify_dry_run('gastronomy', 0);
--
--   -- Vill du också se hur uncategorized skulle klassas med samma dict?
--   select public.reclassify_dry_run('uncategorized', 200);
-- =============================================================================
