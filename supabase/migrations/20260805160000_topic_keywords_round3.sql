-- =============================================================================
-- topic_keywords — runda 3 (2026-08-05, sista utökningsrundan)
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- Sista rundan av keyword-utökningar. Frekvenserna bland kvarvarande
-- uncategorized är nu 27-51 träffar per keyword — svansen. Fortsätta
-- lägga till mindre ökar false-positive-risken utan att lösa bulken.
--
-- Antal nya keywords: 23. Total växer från ~189 → ~212, fortfarande
-- 26 topics.
--
-- SKIPPADE MEDVETET (av principskäl, inte glömda):
--   sustainability, machine learning, sentiment analysis,
--   response surface methodology, qualitative research,
--   sustainable ingredients, ingredient sourcing
-- Alla är forskningsmetoder eller tvärgående teman, inte ämnesområden.
-- En artikel om "machine learning" kan handla om vad som helst.
--
-- Efter denna migration + apply-migration: en sista dry-run visar hur
-- långt vi kommit. Resten som fastnar i uncategorized får sannolikt
-- stå — vi är i svansen där varje keyword räddar 30-50 rader och där
-- specifika termer ger fler false positives än de fångar sanna träffar.
-- =============================================================================

insert into public.topic_keywords (topic, keyword) values

  -- fermentation_science — 5 varianter av fermentation-tema
  ('fermentation_science', 'fermentation science'),
  ('fermentation_science', 'wine fermentation'),
  ('fermentation_science', 'fermentation optimization'),
  ('fermentation_science', 'fermented foods'),          -- plural; runda 1 hade singular
  ('fermentation_science', 'spontaneous fermentation'),

  -- sensory_evaluation — 3 varianter
  ('sensory_evaluation', 'sensory characterization'),
  ('sensory_evaluation', 'organoleptic properties'),
  ('sensory_evaluation', 'sensory experience'),

  -- flavor_science — 2 tillägg. food chemistry hamnar HÄR (inte food_science)
  -- för att keyword-klustret i verkliga data är flavour-analysis-arbete,
  -- inte allmän livsmedelsvetenskap.
  ('flavor_science', 'food chemistry'),
  ('flavor_science', 'maillard reaction'),

  -- food_science — 4 tillägg
  ('food_science', 'physicochemical analysis'),
  ('food_science', 'functional food'),                  -- singular; runda 2 hade plural
  ('food_science', 'food safety microbiology'),
  ('food_science', 'alternative proteins'),

  -- food_psychology — 4 tillägg, consumer/customer-varianter
  ('food_psychology', 'consumer psychology'),
  ('food_psychology', 'consumer attitudes'),
  ('food_psychology', 'consumer segmentation'),
  ('food_psychology', 'customer loyalty'),

  -- hospitality — 1 tillägg
  ('hospitality', 'restaurant management'),

  -- food_anthropology — 3 tillägg. cultural identity i food-kontext är
  -- rimlig; risken för matchning på nationalism-papers är låg eftersom
  -- de sällan har det keyword-fältet.
  ('food_anthropology', 'cultural identity'),
  ('food_anthropology', 'cultural food practices'),
  ('food_anthropology', 'culinary culture'),

  -- gastronomy — 1 tillägg
  ('gastronomy', 'culinary innovation')

on conflict (topic, keyword) do nothing;


-- =============================================================================
-- Verifiering (efter apply):
--
--   -- Bekräfta att totalen växte till ~212:
--   select count(*) from public.topic_keywords;
--
--   -- Fördelning per topic:
--   select topic, count(*) as n
--     from public.topic_keywords
--    group by topic
--    order by n desc;
--
--   -- Sista dry-run:
--   select public.reclassify_dry_run('gastronomy', 0);
--   select public.reclassify_dry_run('uncategorized', 200);
-- =============================================================================
