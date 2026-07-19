-- ============================================================================
-- sample_backfilled_random(p_limit) — spritt slumpstickprov av backfillade.
-- ============================================================================
--
-- Del 3-slutverifiering (2026-07-19). Returnerar N slumpmässiga artiklar
-- ur backfill-populationen (no-role med DOI som fått keywords + sci-scores)
-- för kvalitets-stickprov över hela svepet, inte bara checkpoint-slut-
-- artiklar. Spritt över fetched_at-spektrum och alla källor eftersom
-- ORDER BY random() jämnfördelar över populationen.
--
-- Predikat matchar backfill-fn:s originella population + de vars scores
-- nu skrivits av sweep. Ingen begränsning på score-tröskel (vill se hela
-- utfallet, inklusive marginella som just klarade 5).
--
-- Läs-only. Security definer + grant execute to anon. Samma diagnos-
-- familj som stats/sample/count-RPCer.

create or replace function public.sample_backfilled_random(p_limit int default 20)
returns table (
  id uuid,
  title text,
  source text,
  year text,
  fetched_at timestamptz,
  sensory_pro int,
  culinary_pro int,
  gastronomy_culture int,
  hospitality_mgmt int,
  educator_researcher int,
  max_score int,
  is_role_marked boolean,
  keywords text[],
  study_type text
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
    a.year,
    a.fetched_at,
    a.relevance_sci_sensory_pro         as sensory_pro,
    a.relevance_sci_culinary_pro        as culinary_pro,
    a.relevance_sci_gastronomy_culture  as gastronomy_culture,
    a.relevance_sci_hospitality_mgmt    as hospitality_mgmt,
    a.relevance_sci_educator_researcher as educator_researcher,
    greatest(
      a.relevance_sci_sensory_pro,
      a.relevance_sci_culinary_pro,
      a.relevance_sci_gastronomy_culture,
      a.relevance_sci_hospitality_mgmt,
      a.relevance_sci_educator_researcher
    ) as max_score,
    greatest(
      a.relevance_sci_sensory_pro,
      a.relevance_sci_culinary_pro,
      a.relevance_sci_gastronomy_culture,
      a.relevance_sci_hospitality_mgmt,
      a.relevance_sci_educator_researcher
    ) >= 5 as is_role_marked,
    a.keywords,
    a.study_type
  from articles a
  where a.keywords is not null
    and a.relevance_sci_sensory_pro is not null
    and a.irrelevant = false
    and a.url ilike '%doi.org/%'
  order by random()
  limit p_limit;
$function$;

grant execute on function public.sample_backfilled_random(int) to anon, authenticated;
