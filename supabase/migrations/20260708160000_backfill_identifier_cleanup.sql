-- =====================================================================
-- backfill_progress cleanup: remove abbreviations, duplicates, and arXiv
-- =====================================================================
-- Diagnosed 2026-07-08 during runBackfill svält-analys:
--
--   9 svep använder PubMed-stil förkortningar som SRCTITLE i Scopus
--   (Scopus indexerar på fullt tidskriftsnamn — förkortningarna
--   returnerar 0 träffar konsekvent), varav 4 dessutom har den fulla
--   formen redan i listan (Chem Senses/Chemical Senses,
--   Front Psychol/Frontiers in Psychology, Annu Rev Food Sci Technol/
--   Annual Review..., J Texture Stud/Journal of Texture Studies).
--
--   2 svep pekar på "arXiv" och "arXiv (Cornell University)" —
--   Scopus indexerar inte arXiv, alltid 0 träffar.
--
--   1 duplikat "Trends in Food Science and Technology" (Scopus har
--   den kanoniska titeln med "&" som redan finns).
--
-- Efter denna städning: 91 → 78 Scopus-svep, poolen 112 → 99.
-- Ingenting påverkas för de svep som stannar — bara döda rader
-- rensas så runBackfill inte spenderar sin 20-slot-budget på dem.
-- =====================================================================

delete from public.backfill_progress
where source = 'scopus'
  and identifier in (
    -- PubMed-abbrevs utan full form i listan (Scopus SRCTITLE ger 0)
    'Adv Appl Microbiol',
    'Adv Food Nutr Res',
    'J Am Diet Assoc',
    'J Nutr Educ Behav',
    'J Sci Food Agric',
    'Public Health Nutr',
    -- Abbrev-dubbletter där full form finns kvar
    'Annu Rev Food Sci Technol',
    'Chem Senses',
    'Front Psychol',
    'J Texture Stud',
    -- Ren stavningsdubblett (kanoniska "&"-formen är kvar)
    'Trends in Food Science and Technology',
    -- Scopus indexerar inte arXiv
    'arXiv',
    'arXiv (Cornell University)'
  );

-- =====================================================================
-- Verification (run after apply):
--
--   -- 1. Deleted count matches expectation
--   select count(*) from public.backfill_progress where source='scopus';
--   -- expected: 78 (from 91)
--
--   -- 2. None of the removed identifiers remain
--   select identifier from public.backfill_progress
--    where source = 'scopus'
--      and identifier in ('arXiv','Chem Senses','Front Psychol',
--                         'J Texture Stud','Annu Rev Food Sci Technol',
--                         'Trends in Food Science and Technology');
--   -- expected: 0 rows
--
--   -- 3. Full forms retained
--   select identifier from public.backfill_progress
--    where source = 'scopus'
--      and identifier in ('Chemical Senses','Frontiers in Psychology',
--                         'Journal of Texture Studies',
--                         'Annual Review of Food Science and Technology',
--                         'Trends in Food Science & Technology');
--   -- expected: 5 rows
-- =====================================================================
