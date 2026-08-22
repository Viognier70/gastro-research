-- =============================================================================
-- Cleanup: strippa trailing markdown-separatorer från TRIAD-fälten
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
-- (Augusti-migrationerna är körda mot databasen men saknas i
-- schema_migrations. Se ORDER 091 §8.)
--
-- BAKGRUND (ORDER 124, 2026-08-22):
--
--   Field-audit 2026-08-22: 46 rader har trailing markdown-separatorer
--   (--- / *** / ```) i sitt sparade content — synligt i veckobrev och
--   article-modal. Rot: labeled-triad.ts:parseLabeledProse extraherar
--   text mellan [LABEL]-taggar via slice + trim, men trim tar inte bort
--   markdown-separatorer. Sonnet/Haiku lägger ibland "---" som visuell
--   separator mellan fält i sitt svar — parsern inkluderar dessa i
--   föregående fälts content.
--
--   Fix (samma commit):
--     1. parseLabeledProse strippar trailing (--- / *** / ```) efter trim
--     2. Prompt-regel 9 avråder Sonnet från att skriva separatorer
--     3. Denna migration städar de 46 befintliga raderna
--
--   Regex: `\s*(---+|\*\*\*+|```)\s*$`
--     - Matchar 3+ bindestreck, 3+ asterisker, eller triple-backtick
--     - Omgiven av valfri whitespace
--     - Vid strängens slut
--
-- OMFATTNING: 15 fält × sannolikt <10 rader/fält = ~46 verkliga
-- update:s (audit-räkning). regexp_replace är no-op på icke-matchande
-- content, så SET-listan kan vara komplett — bara raderna som matchar
-- WHERE-clausulen rewrite:as (MVCC).
-- =============================================================================

UPDATE public.articles SET
  episteme_sensory_pro         = regexp_replace(episteme_sensory_pro,         '\s*(---+|\*\*\*+|```)\s*$', ''),
  episteme_culinary_pro        = regexp_replace(episteme_culinary_pro,        '\s*(---+|\*\*\*+|```)\s*$', ''),
  episteme_gastronomy_culture  = regexp_replace(episteme_gastronomy_culture,  '\s*(---+|\*\*\*+|```)\s*$', ''),
  episteme_hospitality_mgmt    = regexp_replace(episteme_hospitality_mgmt,    '\s*(---+|\*\*\*+|```)\s*$', ''),
  episteme_educator_researcher = regexp_replace(episteme_educator_researcher, '\s*(---+|\*\*\*+|```)\s*$', ''),
  techne_sensory_pro           = regexp_replace(techne_sensory_pro,           '\s*(---+|\*\*\*+|```)\s*$', ''),
  techne_culinary_pro          = regexp_replace(techne_culinary_pro,          '\s*(---+|\*\*\*+|```)\s*$', ''),
  techne_gastronomy_culture    = regexp_replace(techne_gastronomy_culture,    '\s*(---+|\*\*\*+|```)\s*$', ''),
  techne_hospitality_mgmt      = regexp_replace(techne_hospitality_mgmt,      '\s*(---+|\*\*\*+|```)\s*$', ''),
  techne_educator_researcher   = regexp_replace(techne_educator_researcher,   '\s*(---+|\*\*\*+|```)\s*$', ''),
  phronesis_sensory_pro        = regexp_replace(phronesis_sensory_pro,        '\s*(---+|\*\*\*+|```)\s*$', ''),
  phronesis_culinary_pro       = regexp_replace(phronesis_culinary_pro,       '\s*(---+|\*\*\*+|```)\s*$', ''),
  phronesis_gastronomy_culture = regexp_replace(phronesis_gastronomy_culture, '\s*(---+|\*\*\*+|```)\s*$', ''),
  phronesis_hospitality_mgmt   = regexp_replace(phronesis_hospitality_mgmt,   '\s*(---+|\*\*\*+|```)\s*$', ''),
  phronesis_educator_researcher= regexp_replace(phronesis_educator_researcher,'\s*(---+|\*\*\*+|```)\s*$', '')
WHERE
  episteme_sensory_pro         ~ '(---+|\*\*\*+|```)\s*$' OR
  episteme_culinary_pro        ~ '(---+|\*\*\*+|```)\s*$' OR
  episteme_gastronomy_culture  ~ '(---+|\*\*\*+|```)\s*$' OR
  episteme_hospitality_mgmt    ~ '(---+|\*\*\*+|```)\s*$' OR
  episteme_educator_researcher ~ '(---+|\*\*\*+|```)\s*$' OR
  techne_sensory_pro           ~ '(---+|\*\*\*+|```)\s*$' OR
  techne_culinary_pro          ~ '(---+|\*\*\*+|```)\s*$' OR
  techne_gastronomy_culture    ~ '(---+|\*\*\*+|```)\s*$' OR
  techne_hospitality_mgmt      ~ '(---+|\*\*\*+|```)\s*$' OR
  techne_educator_researcher   ~ '(---+|\*\*\*+|```)\s*$' OR
  phronesis_sensory_pro        ~ '(---+|\*\*\*+|```)\s*$' OR
  phronesis_culinary_pro       ~ '(---+|\*\*\*+|```)\s*$' OR
  phronesis_gastronomy_culture ~ '(---+|\*\*\*+|```)\s*$' OR
  phronesis_hospitality_mgmt   ~ '(---+|\*\*\*+|```)\s*$' OR
  phronesis_educator_researcher~ '(---+|\*\*\*+|```)\s*$';


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Räkna igen — borde vara 0 efter migrationen
--   SELECT
--     count(*) FILTER (WHERE phronesis_sensory_pro         ~ '(---+|\*\*\*+|```)\s*$') +
--     count(*) FILTER (WHERE phronesis_culinary_pro        ~ '(---+|\*\*\*+|```)\s*$') +
--     count(*) FILTER (WHERE phronesis_gastronomy_culture  ~ '(---+|\*\*\*+|```)\s*$') +
--     count(*) FILTER (WHERE phronesis_hospitality_mgmt    ~ '(---+|\*\*\*+|```)\s*$') +
--     count(*) FILTER (WHERE phronesis_educator_researcher ~ '(---+|\*\*\*+|```)\s*$') +
--     count(*) FILTER (WHERE techne_sensory_pro            ~ '(---+|\*\*\*+|```)\s*$') +
--     count(*) FILTER (WHERE techne_culinary_pro           ~ '(---+|\*\*\*+|```)\s*$') +
--     count(*) FILTER (WHERE techne_gastronomy_culture     ~ '(---+|\*\*\*+|```)\s*$') +
--     count(*) FILTER (WHERE techne_hospitality_mgmt       ~ '(---+|\*\*\*+|```)\s*$') +
--     count(*) FILTER (WHERE techne_educator_researcher    ~ '(---+|\*\*\*+|```)\s*$') +
--     count(*) FILTER (WHERE episteme_sensory_pro          ~ '(---+|\*\*\*+|```)\s*$') +
--     count(*) FILTER (WHERE episteme_culinary_pro         ~ '(---+|\*\*\*+|```)\s*$') +
--     count(*) FILTER (WHERE episteme_gastronomy_culture   ~ '(---+|\*\*\*+|```)\s*$') +
--     count(*) FILTER (WHERE episteme_hospitality_mgmt     ~ '(---+|\*\*\*+|```)\s*$') +
--     count(*) FILTER (WHERE episteme_educator_researcher  ~ '(---+|\*\*\*+|```)\s*$') AS still_contaminated
--   FROM public.articles;
--   -- expected: 0
--
--   -- 2. Spot-check en rad som var kontaminerad — "Human perceptions
--   --    drive cultural food choice patterns" om den finns:
--   -- SELECT phronesis_sensory_pro FROM public.articles
--   --  WHERE title ILIKE '%Human perceptions drive cultural food%'
--   --  LIMIT 1;
--   -- expected: text som slutar på . ! ? eller ) — inte på ---
--
--   -- 3. Nya analyser via triad-on-demand / pipeline / triad-background
--   --    ska nu skrivas rent tack vare parseLabeledProse-uppdateringen
--   --    (verifieras vid nästa körning). Prompt-regel 9 minskar hur ofta
--   --    Sonnet skickar separatorer alls.
-- =============================================================================
