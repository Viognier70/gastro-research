-- ============================================================================
-- stats_no_role_null_kw() — engångs-diagnostik för Del 3 backfill-strategi.
-- ============================================================================
--
-- Bakgrund: 2026-07-17 utredning identifierade 13 094 no-role-artiklar med
-- keywords=null + DOI. Anon-baserad räkning kunde inte splitta på
-- abstract-längd (fältet Pro-låst i articles_public) och gav proxy via
-- sci_ko=3762 (~29% Haiku-eligible). Innan haiku-sci.ts-extraktionen +
-- kombinerad backfill (Haiku-först, OpenAlex-fallback) byggs vill Anders
-- direkta tal på:
--
--   1. ABSTRACT-LÄNGD: hur många har length(abstract) > 50 / > 200 osv?
--      (avgör vad Haiku faktiskt kan generera keywords på)
--   2. HAIKU-KÖRSTATUS: hur många har relevance_sci_sensory_pro NOT NULL
--      (Haiku har körts) vs NULL (aldrig körd)
--   3. SOURCE-FÖRDELNING: exakt count openalex/scopus/pubmed/annat (anon
--      en-i-taget gav 500 på openalex)
--
-- Funktionen är SECURITY DEFINER + granted till anon för att undvika manuell
-- service_role-nyckelhantering (samma princip som backfill-openalex-terms-fn:
-- läsning skyddad vid källan, inte via klientnyckel). Returnerar jsonb med
-- alla tre buckets i EN round-trip.
--
-- Ej idempotent på semantiken (räknar just nu-läget), men create or replace
-- gör själva RPC:n idempotent.

create or replace function public.stats_no_role_null_kw()
returns jsonb
language sql
security definer
stable
set search_path = public
as $function$
  with pop as (
    select id, abstract, source, relevance_sci_sensory_pro
    from articles
    where irrelevant = false
      and keywords is null
      and url ilike '%doi.org/%'
      and (relevance_sci_sensory_pro < 5 or relevance_sci_sensory_pro is null)
      and (relevance_sci_culinary_pro < 5 or relevance_sci_culinary_pro is null)
      and (relevance_sci_gastronomy_culture < 5 or relevance_sci_gastronomy_culture is null)
      and (relevance_sci_hospitality_mgmt < 5 or relevance_sci_hospitality_mgmt is null)
      and (relevance_sci_educator_researcher < 5 or relevance_sci_educator_researcher is null)
  ),
  no_doi_pop as (
    select id, abstract from articles
    where irrelevant = false
      and keywords is null
      and (url is null or url not ilike '%doi.org/%')
      and (relevance_sci_sensory_pro < 5 or relevance_sci_sensory_pro is null)
      and (relevance_sci_culinary_pro < 5 or relevance_sci_culinary_pro is null)
      and (relevance_sci_gastronomy_culture < 5 or relevance_sci_gastronomy_culture is null)
      and (relevance_sci_hospitality_mgmt < 5 or relevance_sci_hospitality_mgmt is null)
      and (relevance_sci_educator_researcher < 5 or relevance_sci_educator_researcher is null)
  )
  select jsonb_build_object(
    'total_with_doi', (select count(*) from pop),
    'total_no_doi',   (select count(*) from no_doi_pop),

    -- (1) ABSTRACT-LÄNGDBUCKETS för DOI-populationen (Haiku-eligible-frågan)
    'abstract_null',           (select count(*) from pop where abstract is null),
    'abstract_unavailable',    (select count(*) from pop where abstract = '[unavailable]'),
    'abstract_1_50',           (select count(*) from pop where abstract is not null and abstract <> '[unavailable]' and length(abstract) between 1 and 50),
    'abstract_51_200',         (select count(*) from pop where length(abstract) between 51 and 200),
    'abstract_201_plus',       (select count(*) from pop where length(abstract) > 200),
    -- Sci_ko-predikatets exakta gräns: length > 50 (matchar claim_pipeline_batch)
    'abstract_gt_50_haiku_eligible', (select count(*) from pop where abstract is not null and abstract <> '[unavailable]' and length(abstract) > 50),

    -- (2) HAIKU-KÖRSTATUS
    'haiku_ran',   (select count(*) from pop where relevance_sci_sensory_pro is not null),
    'haiku_never', (select count(*) from pop where relevance_sci_sensory_pro is null),

    -- (3) SOURCE-FÖRDELNING
    'source_openalex',        (select count(*) from pop where source = 'openalex'),
    'source_scopus',          (select count(*) from pop where source = 'scopus'),
    'source_pubmed',          (select count(*) from pop where source = 'pubmed'),
    'source_semanticscholar', (select count(*) from pop where source = 'semanticscholar'),
    'source_crossref',        (select count(*) from pop where source = 'crossref'),
    'source_other_or_null',   (select count(*) from pop where source is null or source not in ('openalex','scopus','pubmed','semanticscholar','crossref')),

    -- No-DOI-svansen: abstract-status (för de 16 sub-populationen)
    'no_doi_abstract_gt_50', (select count(*) from no_doi_pop where abstract is not null and abstract <> '[unavailable]' and length(abstract) > 50),
    'no_doi_abstract_short_or_null', (select count(*) from no_doi_pop where abstract is null or abstract = '[unavailable]' or length(abstract) <= 50)
  );
$function$;

grant execute on function public.stats_no_role_null_kw() to anon, authenticated;
