-- =============================================================================
-- knowledge_map_topics() — server-side ämnesaggregering för Explore-vyn
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- BAKGRUND:
--
--   loadKnowledgeMap (index.html:3691) hämtade articles_public med limit=5000
--   och aggregerade topic-count + role-relevance-medelvärden client-side.
--   PostgREST-tak 1 000 gjorde att aggregeringen körde över 0.2 % av korpusen
--   (~1 000 av ~466 000 rader) — Explore visade skev ämnesfördelning tyst.
--   Sjunde incidenten där db-max-rows=1000 kapar en visning som gör anspråk
--   på att representera hela korpusen.
--
--   Även: gamla queryn filtrerade INTE på irrelevant. Bifynd, samma familj
--   som funnel-fix 2026-08-02.
--
-- LÖSNING:
--
--   Ren RPC (inte MV). EXPLAIN ANALYZE 2026-08-05 gav 892 ms över hela
--   corpusen — under 3 s-tröskeln i docs/postgrest-caps.md, så materialiserad
--   vy är overkill. Data ändras kontinuerligt (nytt inflöde via daily-fetch +
--   forward-jobb), on-demand-beräkning kostar mindre än refresh-cron.
--
--   Returnerar JSONB-array (en rad) → bypass av per-row-cappet, ingen
--   paginering behövs.
--
-- FÄLTNAMN:
--
--   rel_sommelier/chef/creator/waiter/educator matchar exakt frontendens
--   getTopicRelevance (index.html:3728-3731) som gör `t['rel_'+role]`. Ingen
--   client-side-mappning behövs — RPC-svaret används direkt som mapTopicData
--   (utom `label` som fylls från TOPIC_LABELS-dict i frontend).
-- =============================================================================

create or replace function public.knowledge_map_topics()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'topic',          topic,
        'count',          count,
        'recent',         recent,
        'rel_sommelier',  rel_sensory,
        'rel_chef',       rel_culinary,
        'rel_creator',    rel_gastronomy,
        'rel_waiter',     rel_hospitality,
        'rel_educator',   rel_educator
      )
      order by count desc
    ),
    '[]'::jsonb
  )
  from (
    select
      topic,
      count(*)::int as count,
      count(*) filter (where fetched_at > now() - interval '7 days')::int as recent,
      avg(relevance_sci_sensory_pro)         filter (where relevance_sci_sensory_pro         is not null) as rel_sensory,
      avg(relevance_sci_culinary_pro)        filter (where relevance_sci_culinary_pro        is not null) as rel_culinary,
      avg(relevance_sci_gastronomy_culture)  filter (where relevance_sci_gastronomy_culture  is not null) as rel_gastronomy,
      avg(relevance_sci_hospitality_mgmt)    filter (where relevance_sci_hospitality_mgmt    is not null) as rel_hospitality,
      avg(relevance_sci_educator_researcher) filter (where relevance_sci_educator_researcher is not null) as rel_educator
    from public.articles
    where irrelevant is not true
      and topic is not null
    group by topic
  ) t
$function$;

revoke all on function public.knowledge_map_topics() from public;
grant execute on function public.knowledge_map_topics() to anon, authenticated, service_role;


-- =============================================================================
-- Verifiering (efter apply):
--
--   -- 1. Antal topics i svaret (baseline 2026-08-05: TOPICS-dict i daily-
--   --    fetch:114-112 har ~26 nycklar + 'uncategorized' + legacy):
--   select jsonb_array_length(public.knowledge_map_topics());
--   -- expected: 25-40 rader
--
--   -- 2. Två-tre största topics:
--   select value from jsonb_array_elements(public.knowledge_map_topics())
--    limit 3;
--
--   -- 3. Grants:
--   select has_function_privilege('anon',
--     'public.knowledge_map_topics()', 'EXECUTE');  -- expect true
-- =============================================================================
