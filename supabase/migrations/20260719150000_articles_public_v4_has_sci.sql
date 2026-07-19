-- articles_public v4 — lägg till has_sci_${role} bredvid has_episteme_${role}.
--
-- Bakgrund (verifierat 2026-07-19):
--   Del 3-backfillen skrev relevance_sci_* + keywords + core_claim +
--   headline_en + study_type till ~13k no-role-artiklar via Metod B (queue
--   status='skipped', TRIAD blockad från kaskad). Backfillen är RENT
--   (99% täckning, 20/20 slumpstickprov utan brus).
--
--   MEN feed-filtret läser bara has_episteme_${role}=is.true, som kräver
--   episteme_${role} IS NOT NULL. Vår backfill körde bara sci (Haiku), inte
--   TRIAD (Sonnet), så episteme_* förblir NULL → has_episteme=false →
--   backfillade artiklar OSYNLIGA i feed. 27 111 artiklar i limbo.
--
-- FIX (alt B): lägg till has_sci_${role} = (relevance_sci_${role} >= 5).
-- Behåll has_episteme_${role} oförändrad (fortfarande "full TRIAD-payload
-- finns"). Frontenden feed-filter ändras till
-- or=(has_episteme.is.true, has_sci.is.true) i separat commit.
--
-- SEMANTIK EFTER FIX:
--   has_episteme_${role} = "full TRIAD-payload klar (Sonnet körd)"
--   has_sci_${role}      = "role-relevant enligt Haiku (score >= 5)"
-- Card-render skiljer redan: hasPremiumPayload → "Show TRIAD",
-- hasTriadPresence-only (Free) → "Upgrade", ingen TRIAD → "Analyze TRIAD".
-- Sci-only artiklar faller i "Analyze TRIAD"-branschen (rätt CTA för
-- on-demand Sonnet). Ingen card-render-ändring behövs.
--
-- ORDNING: DENNA migration FÖRE frontend-fix. Feed-filtret kan inte fråga
-- efter has_sci innan kolumnen finns.
--
-- pg_depend: samma antagande som v3 — inga externa deps på articles_public.
-- Drop+create för konsistens (inte cascade eftersom vi ersätter, inte tar
-- bort).

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
   -- Presence-booleans för TRIAD-analys per science-roll (oförändrat)
   (episteme_sensory_pro         is not null) as has_episteme_sensory_pro,
   (episteme_culinary_pro        is not null) as has_episteme_culinary_pro,
   (episteme_gastronomy_culture  is not null) as has_episteme_gastronomy_culture,
   (episteme_hospitality_mgmt    is not null) as has_episteme_hospitality_mgmt,
   (episteme_educator_researcher is not null) as has_episteme_educator_researcher,
   -- Sci-scored per role (NY 2026-07-19) — role-relevant enligt Haiku
   -- utan att kräva full TRIAD-payload. Frontenden feed-filter läser
   -- or=(has_episteme, has_sci) för att inkludera backfillade + äldre
   -- sci-scored artiklar.
   (relevance_sci_sensory_pro         >= 5) as has_sci_sensory_pro,
   (relevance_sci_culinary_pro        >= 5) as has_sci_culinary_pro,
   (relevance_sci_gastronomy_culture  >= 5) as has_sci_gastronomy_culture,
   (relevance_sci_hospitality_mgmt    >= 5) as has_sci_hospitality_mgmt,
   (relevance_sci_educator_researcher >= 5) as has_sci_educator_researcher,
   -- Metadata-presence
   (core_claim         is not null) as has_core_claim,
   (imrad_introduction is not null) as has_imrad
 from public.articles;

grant select on public.articles_public to anon, authenticated, service_role;

-- Verifiering (efter apply):
--   -- 1. has_sci_ finns nu?
--   select column_name from information_schema.columns
--    where table_schema='public' and table_name='articles_public'
--      and column_name like 'has_sci_%';
--   -- expected: 5 rader
--
--   -- 2. has_sci_sensory_pro räknar rätt (jämför med relevance_sci >= 5):
--   select
--     count(*) filter (where has_sci_sensory_pro) as via_flag,
--     count(*) filter (where relevance_sci_sensory_pro >= 5) as direct
--   from public.articles_public
--   where irrelevant = false;
--   -- expected: via_flag == direct
--
--   -- 3. has_episteme_sensory_pro oförändrad (matchar TRIAD-populationen):
--   select count(*) from public.articles_public
--   where has_episteme_sensory_pro and irrelevant = false;
--   -- expected: ~5053 (samma som pre-migration)
