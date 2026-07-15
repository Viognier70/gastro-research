-- articles_public v3 — exponera `keywords` bredvid dead-column `claim_keywords`.
--
-- Bakgrund (verifierat 2026-07-15):
--   articles.keywords         → 18 352 ifyllda, rik data (pipeline u.keywords)
--   articles.claim_keywords   → 253 gamla, ingen aktiv skrivare
-- Men vyn exponerar bara claim_keywords → frontend visar ~inga keywords
-- trots att 18 352 finns. Tystfel sedan pipeline bytte skrivmål.
--
-- Denna migration LÄGGER TILL keywords i vyn utan att röra claim_keywords.
-- Frontend byter läsning i samma commit (index.html rad 2282 + 3 FIELDS-
-- strängar). Kolumnen claim_keywords droppas i EGEN senare migration efter
-- att live-frontend körts en tid utan den — så vi inte bryter deployglipan.
--
-- pg_depend: kolla igen om det känns osäkert. Senaste mätning
-- (2026-07-13, doc-block i v2) sa 0 dependencies på articles_public.
-- Om något skulle beroende ha lagts till efter dess: cascade behövs INTE
-- (create view kan ersätta) — men eftersom vi har historisk convention av
-- drop+create för att inte ärva stale grants, gör vi det så här igen.

drop view if exists public.articles_public;

create view public.articles_public as
 select
   id, title, headline_en, headline_sv, insight, authors, journal, year,
   topic, url, citation_count, fetched_at, source, source_label, study_type,
   knowledge_type, country, countries, keywords, claim_keywords, limitation,
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

-- Verifiering (efter apply):
--   -- 1. keywords nu i vyn?
--   select column_name from information_schema.columns
--    where table_schema='public' and table_name='articles_public'
--      and column_name in ('keywords','claim_keywords');
--   -- expected: 2 rader
--
--   -- 2. Rik data levereras?
--   select id, keywords[1:3], claim_keywords[1:3]
--     from public.articles_public
--    where keywords is not null and array_length(keywords,1) > 0
--    limit 5;
