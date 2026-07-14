-- Drop av 81 legacy chip-namn-kolumner från articles-tabellen.
--
-- KRÄVER att 20260713140000_articles_public_v2_no_chip.sql redan är kört —
-- vyn måste sluta referera dessa kolumner först, annars misslyckas DROP
-- med "cannot drop column X because other objects depend on it".
--
-- Bakgrund: chip-namn (episteme_sommelier, techne_chef m.fl.) fylldes senast
-- 2026-05-24, långt före labeled-prose-övergången (2026-07-05). Prompten som
-- genererade dem finns inte i git och är semantiskt annorlunda från dagens
-- labeled-prose-format. Anders (2026-07-13) beslut: släng, låt de 1 428
-- artiklarna re-analyseras av triad-background (~$66 Sonnet-cost över 30
-- dagar, budget 50/dag). Bättre än att blanda två prompt-generationer.
--
-- Ingen CASCADE — pg_depend-check visade noll beroenden efter att
-- articles_public rensats.
--
-- KATEGORIER (81 kolumner):
--
--   Kanoniska chip-roller (5): sommelier, chef, gastronomy, fb_manager,
--                              food_researcher
--   Short-chip aliaser (4):    creator (=meal_creator), educator (=food_
--                              researcher), fbmanager (=fb_manager utan
--                              underscore), waiter (v1 hospitality)
--   Pre-Gustema (5):           hotelier, pastry_chef, restaurantmanager,
--                              winebar, researcher (deprecated alias)
--   Bridge-varianter (2):      bridge_episteme_techne_${chip}, bridge_
--                              techne_phronesis_${chip} × 5 kanoniska
--   Legacy relevance-shapes:   relevance_${chip} (utan sci_), relevance_sci_
--                              ${chip}, relevance_val_${chip} (dead scoring)
--
-- KRITIKALITET: OÅTERKALLELIGT. Data i dessa kolumner är
-- oåterhämtningsbar efter körning. Verifierat 2026-07-13 att:
--   • Alla writer-anrop använder science-namn (via lint scripts/lint-role-
--     columns.sh, sedan c84dc9b)
--   • articles_public v2 (föregående migration) exponerar bara science-varianter
--   • 1 428 rader har chip-only-data — anses acceptabel förlust; re-analyseras

alter table public.articles
  drop column bridge_episteme_techne_chef,
  drop column bridge_episteme_techne_fb_manager,
  drop column bridge_episteme_techne_food_researcher,
  drop column bridge_episteme_techne_gastronomy,
  drop column bridge_episteme_techne_sommelier,
  drop column bridge_techne_phronesis_chef,
  drop column bridge_techne_phronesis_fb_manager,
  drop column bridge_techne_phronesis_food_researcher,
  drop column bridge_techne_phronesis_gastronomy,
  drop column bridge_techne_phronesis_sommelier,
  drop column episteme_chef,
  drop column episteme_creator,
  drop column episteme_educator,
  drop column episteme_fb_manager,
  drop column episteme_fbmanager,
  drop column episteme_food_researcher,
  drop column episteme_gastronomy,
  drop column episteme_hotelier,
  drop column episteme_pastry_chef,
  drop column episteme_researcher,
  drop column episteme_restaurantmanager,
  drop column episteme_sommelier,
  drop column episteme_waiter,
  drop column episteme_winebar,
  drop column phronesis_chef,
  drop column phronesis_creator,
  drop column phronesis_educator,
  drop column phronesis_fb_manager,
  drop column phronesis_fbmanager,
  drop column phronesis_food_researcher,
  drop column phronesis_gastronomy,
  drop column phronesis_hotelier,
  drop column phronesis_pastry_chef,
  drop column phronesis_researcher,
  drop column phronesis_restaurantmanager,
  drop column phronesis_sommelier,
  drop column phronesis_waiter,
  drop column phronesis_winebar,
  drop column relevance_chef,
  drop column relevance_creator,
  drop column relevance_educator,
  drop column relevance_fbmanager,
  drop column relevance_hotelier,
  drop column relevance_pastry_chef,
  drop column relevance_researcher,
  drop column relevance_restaurantmanager,
  drop column relevance_sci_chef,
  drop column relevance_sci_creator,
  drop column relevance_sci_educator,
  drop column relevance_sci_fb_manager,
  drop column relevance_sci_fbmanager,
  drop column relevance_sci_food_researcher,
  drop column relevance_sci_gastronomy,
  drop column relevance_sci_hotelier,
  drop column relevance_sci_researcher,
  drop column relevance_sci_restaurantmanager,
  drop column relevance_sci_sommelier,
  drop column relevance_sci_waiter,
  drop column relevance_sci_winebar,
  drop column relevance_sommelier,
  drop column relevance_val_chef,
  drop column relevance_val_creator,
  drop column relevance_val_educator,
  drop column relevance_val_sommelier,
  drop column relevance_val_waiter,
  drop column relevance_waiter,
  drop column relevance_winebar,
  drop column techne_chef,
  drop column techne_creator,
  drop column techne_educator,
  drop column techne_fb_manager,
  drop column techne_fbmanager,
  drop column techne_food_researcher,
  drop column techne_gastronomy,
  drop column techne_hotelier,
  drop column techne_pastry_chef,
  drop column techne_researcher,
  drop column techne_restaurantmanager,
  drop column techne_sommelier,
  drop column techne_waiter,
  drop column techne_winebar;
