-- articles_public v2 — kontraktfasen: chip-namn-kolumner bort ur vyn.
--
-- Denna migration MÅSTE köras före drop av chip-kolumnerna på articles-
-- tabellen (20260713140100). Utan detta steg misslyckas ALTER TABLE DROP
-- med "cannot drop columns from view".
--
-- Bakgrund: sedan namnrymdsmigrationen 2026-07-12 skriver ingen writer
-- (pipeline, triad-on-demand, triad-background) chip-kolumner. Legacy chip-
-- data i tabellen är från 2026-05-04..05-24 och genererad med en tidigare
-- prompt-generation som inte finns kvar i git. Behåll den i vyn = fortsätt
-- exponera dorm data som ny kod kan råka interpolera.
--
-- pg_depend-check 2026-07-13: 0 dependencies på articles_public (varken
-- vyer eller funktioner). Säker att drop utan CASCADE.
--
-- Vad tas bort ur SELECT-listan (jämfört med v1):
--   Chip relevance_ (8):        relevance_sommelier, _chef, _creator, _waiter,
--                               _educator, _researcher, _fbmanager, _hotelier
--   Chip relevance_sci_ (10):   _sommelier, _chef, _gastronomy, _fb_manager,
--                               _food_researcher, _creator, _fbmanager,
--                               _researcher, _waiter, _educator
--   Chip has_episteme_ (5):     _sommelier, _chef, _gastronomy, _fb_manager,
--                               _food_researcher
--
-- Vad KVARSTÅR:
--   5 science relevance_sci_ (sensory_pro/culinary_pro/gastronomy_culture/
--                             hospitality_mgmt/educator_researcher)
--   5 science has_episteme_   (samma 5 science-roller)
--   All metadata (id/title/journal/etc), irrelevant, has_core_claim,
--   has_imrad, institutions, institution_coords, institution_rank
--
-- Efter denna migration är vyn 27 kolumner mindre. Frontend läser bara
-- science-varianter (verifierat med scripts/lint-role-columns.sh) så inget
-- läge går sönder.

drop view if exists public.articles_public;

create view public.articles_public as
 select
   id, title, headline_en, headline_sv, insight, authors, journal, year,
   topic, url, citation_count, fetched_at, source, source_label, study_type,
   knowledge_type, country, countries, claim_keywords, limitation,
   primary_institution, institution_coords, institution_rank, institutions,
   irrelevant,
   -- Sci-relevance (5 science-namn — enda som pipeline skriver)
   relevance_sci_sensory_pro,
   relevance_sci_culinary_pro,
   relevance_sci_gastronomy_culture,
   relevance_sci_hospitality_mgmt,
   relevance_sci_educator_researcher,
   -- Presence-booleans för TRIAD-analys per science-roll
   (episteme_sensory_pro         is not null) as has_episteme_sensory_pro,
   (episteme_culinary_pro        is not null) as has_episteme_culinary_pro,
   (episteme_gastronomy_culture  is not null) as has_episteme_gastronomy_culture,
   (episteme_hospitality_mgmt    is not null) as has_episteme_hospitality_mgmt,
   (episteme_educator_researcher is not null) as has_episteme_educator_researcher,
   -- Metadata-presence
   (core_claim         is not null) as has_core_claim,
   (imrad_introduction is not null) as has_imrad
 from public.articles;

grant select on public.articles_public to anon, authenticated, service_role;
