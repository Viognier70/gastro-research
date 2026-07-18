-- ============================================================================
-- fetch_backfill_haiku_batch(p_limit) — pending-först populationsfetch.
-- ============================================================================
--
-- Returnerar N artiklar ur Del 3-populationen (no-role + null-kw + DOI +
-- abstract > 50) med pending-FÖRST + fetched_at ASC (motsats-ordering till
-- pipelinens fetched_at DESC → minimerar race på samma artiklar).
--
-- Två-fas i EN query via UNION ALL + sort_order:
--   Fas 1 (sort_order=0): artiklar med processing_queue.status='pending'
--     → Metod B UPDATE:ar dessa till 'skipped' efter Haiku-write (kritiskt
--       för att förhindra pipeline-plock efter backfill).
--   Fas 2 (sort_order=1): artiklar UTAN processing_queue-rad (absent)
--     → Metod B:s UPDATE är no-op för dem (harmlöst), pipeline vet inget om
--       dessa.
--
-- Guard `relevance_sci_sensory_pro IS NULL` i predikatet ger idempotens —
-- redan-skrivna artiklar hamnar aldrig i resultatet.
--
-- SECURITY: security definer, grant execute till service_role (edge fn).
-- INTE grant till anon — läser abstract som är Pro-gate:ad på articles_public.

create or replace function public.fetch_backfill_haiku_batch(p_limit int)
returns table (
  id uuid,
  title text,
  abstract text,
  journal text,
  phase text
)
language sql
security definer
stable
set search_path = public
as $function$
  with pop_predicate as (
    select a.id, a.title, a.abstract, a.journal, a.fetched_at
    from articles a
    where a.irrelevant = false
      and a.keywords is null
      and a.url ilike '%doi.org/%'
      and a.abstract is not null
      and a.abstract <> '[unavailable]'
      and length(a.abstract) > 50
      and a.relevance_sci_sensory_pro is null
      and (a.relevance_sci_culinary_pro < 5 or a.relevance_sci_culinary_pro is null)
      and (a.relevance_sci_gastronomy_culture < 5 or a.relevance_sci_gastronomy_culture is null)
      and (a.relevance_sci_hospitality_mgmt < 5 or a.relevance_sci_hospitality_mgmt is null)
      and (a.relevance_sci_educator_researcher < 5 or a.relevance_sci_educator_researcher is null)
  ),
  pending_batch as (
    select p.id, p.title, p.abstract, p.journal, p.fetched_at,
           'pending'::text as phase, 0 as sort_order
    from pop_predicate p
    join processing_queue q on q.article_id = p.id
    where q.status = 'pending'
    order by p.fetched_at asc
    limit p_limit
  ),
  absent_batch as (
    select p.id, p.title, p.abstract, p.journal, p.fetched_at,
           'absent'::text as phase, 1 as sort_order
    from pop_predicate p
    where not exists (select 1 from processing_queue q where q.article_id = p.id)
    order by p.fetched_at asc
    limit p_limit
  ),
  combined as (
    select * from pending_batch
    union all
    select * from absent_batch
  )
  select id, title, abstract, journal, phase
  from combined
  order by sort_order, fetched_at asc
  limit p_limit;
$function$;

grant execute on function public.fetch_backfill_haiku_batch(int) to service_role;
revoke execute on function public.fetch_backfill_haiku_batch(int) from public, anon, authenticated;
