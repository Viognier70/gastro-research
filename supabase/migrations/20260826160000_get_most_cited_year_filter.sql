-- ORDER 174: get_most_cited — årsfilter för att undvika ålders-ranking.
--
-- Bakgrund: efter ORDER 175 citation-backfill (2026-08-26) har 28 750
-- artiklar citation_count > 0 (var 123 tidigare). Utan årsfilter blir
-- "Most cited"-panelen en åldersranking — en artikel från 2005 har 20
-- års citeringsförsprång och trycker undan aktuell forskning.
--
-- Frontend defaultar filter_year_min = current_year - 5 (2026 → 2021),
-- vilket matchar underlaget: 21 557 artiklar publicerade 2021 eller
-- senare har citation_count > 0.
--
-- Ändring: ny parameter `filter_year_min integer default null`.
-- WHERE-klausul: (filter_year_min is null or a.year >= filter_year_min::text).
--
-- Varför lexicographic (a.year >= '2021') snarare än ::int-cast:
-- articles.year är TEXT. Alla värden är 4-siffriga (verifierat via
-- schemat i landings-cuts), så lex-jämförelse är ekvivalent med numerisk
-- OCH tål ovanliga icke-numeriska värden utan cast-error. NULL-year
-- filtreras ut naturligt (NULL >= '2021' → NULL → false), vilket är
-- korrekt beteende — vi vill inte visa citations där år saknas.
--
-- Signaturen är additiv (ny param med default) — existerande callers
-- utan filter_year_min fortsätter fungera. Grants preserveras av
-- CREATE OR REPLACE.

create or replace function public.get_most_cited(
  limit_n integer default 10,
  filter_topic text default null,
  filter_keyword text default null,
  filter_role text default null,
  filter_year_min integer default null
)
returns table(
  id uuid,
  title text,
  journal text,
  year text,
  citation_count integer,
  topic text,
  url text,
  headline_en text,
  relevance_score integer
)
language sql
security definer
as $function$
  select
    a.id, a.title, a.journal, a.year,
    a.citation_count, a.topic, a.url, a.headline_en,
    coalesce(case filter_role
      when 'sensory_pro'         then a.relevance_sci_sensory_pro
      when 'culinary_pro'        then a.relevance_sci_culinary_pro
      when 'gastronomy_culture'  then a.relevance_sci_gastronomy_culture
      when 'hospitality_mgmt'    then a.relevance_sci_hospitality_mgmt
      when 'educator_researcher' then a.relevance_sci_educator_researcher
      else 0
    end, 0) as relevance_score
  from articles a
  where a.citation_count is not null
    and a.citation_count > 0
    and (filter_topic is null or a.topic = filter_topic)
    and (filter_keyword is null or filter_keyword = any(a.keywords))
    and (filter_year_min is null or a.year >= filter_year_min::text)
  order by a.citation_count desc
  limit limit_n;
$function$;


-- =============================================================================
-- Verifiering efter apply:
--
--   -- 1. Signature har filter_year_min:
--   select pg_get_function_identity_arguments(oid)
--   from pg_proc where proname='get_most_cited'
--     and pronamespace='public'::regnamespace;
--   -- expected: "limit_n integer, filter_topic text, filter_keyword text,
--   --            filter_role text, filter_year_min integer"
--
--   -- 2. Utan årsfilter — legacy-beteende:
--   select count(*) from public.get_most_cited(50000, null, null, null, null);
--   -- expected: ~28 750 (alla med citation_count > 0)
--
--   -- 3. Med 2021-cutoff (default från frontend):
--   select count(*) from public.get_most_cited(50000, null, null, null, 2021);
--   -- expected: ~21 557
--
--   -- 4. Topp 5 sedan 2021 — ingen ska ha år < 2021:
--   select year, citation_count, title
--   from public.get_most_cited(5, null, null, null, 2021);
--   -- expected: samtliga year >= '2021', sorterade på citation_count desc.
