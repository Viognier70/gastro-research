-- ============================================================================
-- sample_no_role_null_kw(n int) — stickprov från Del 3-populationen.
-- ============================================================================
--
-- Systerfunktion till stats_no_role_null_kw() (20260718100000). Returnerar
-- N slumpmässiga artiklar ur samma predikat (no-role + null-kw + DOI) med
-- id, title, source, url, abstract-length OCH abstract-utdrag (första 300
-- tecken) så Anders kan sanity-checka att:
--   1. abstracts är RIKTIGA (inte boilerplate/[unavailable] som passerar
--      längdgränsen men är oanvändbara för Haiku)
--   2. Haiku-prompten kan köras manuellt mot dessa abstracts
--
-- Läs-only, security definer, grant execute to anon (samma mönster som
-- stats_no_role_null_kw + get_gusto_health-familjen).

create or replace function public.sample_no_role_null_kw(n int default 5)
returns table (
  id uuid,
  title text,
  source text,
  url text,
  abstract_length int,
  abstract_snippet text
)
language sql
security definer
stable
set search_path = public
as $function$
  select
    a.id,
    a.title,
    a.source,
    a.url,
    length(a.abstract) as abstract_length,
    left(a.abstract, 300) as abstract_snippet
  from articles a
  where a.irrelevant = false
    and a.keywords is null
    and a.url ilike '%doi.org/%'
    and (a.relevance_sci_sensory_pro < 5 or a.relevance_sci_sensory_pro is null)
    and (a.relevance_sci_culinary_pro < 5 or a.relevance_sci_culinary_pro is null)
    and (a.relevance_sci_gastronomy_culture < 5 or a.relevance_sci_gastronomy_culture is null)
    and (a.relevance_sci_hospitality_mgmt < 5 or a.relevance_sci_hospitality_mgmt is null)
    and (a.relevance_sci_educator_researcher < 5 or a.relevance_sci_educator_researcher is null)
    and a.abstract is not null
    and length(a.abstract) > 50
  order by random()
  limit n;
$function$;

grant execute on function public.sample_no_role_null_kw(int) to anon, authenticated;
