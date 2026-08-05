-- =============================================================================
-- Institutionspanelen: dölj 'uncategorized' + fler OpenAlex-koncept i blocklist
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- Feedback från Örebro-panelen 2026-08-06:
--   1. 'uncategorized' är största ämnet (9 av 36) — säger inget om
--      institutionens forskning, bara att keywords inte matchade
--      TOPICS-dicten. Fältet ska inte visas i panelen.
--   2. OpenAlex-konceptetiketter i Title Case läcker igenom (Meal,
--      "Organic Food and Agriculture", "Culinary Culture and Tourism",
--      "Sensory Analysis and Statistical Methods").
--
-- FIX:
--
--   1. map_institution_detail-RPC:n filtrerar bort topic = 'uncategorized'
--      i topic_counts-CTE:n. Inte i frontenden — bättre att låta RPC:n
--      returnera det som ska visas.
--
--   2. Blocklistan får de fyra observerade + noteras: framtida Title Case-
--      koncept adderas individuellt tills mönstret är breddat nog att
--      motivera regel-baserad filtrering.
--
--      REGEL-ALTERNATIVET (medvetet ej implementerat):
--      Multi-word Title Case (regex ^[A-Z][a-z]+(\s+(and|of|in|for|the)\s+
--      [A-Z][a-z]+|\s+[A-Z][a-z]+)+$) skulle fånga fler koncept, men
--      falsk-positiv-risken är hög — legitima Title Case-termer som
--      "Traditional Chinese Medicine", "Slow Food", "Wine Pairing" (om
--      OpenAlex råkar lagra Title Case i något keyword-fält) skulle
--      också filtreras. Utan breddad testdata svårt att avgöra hur många
--      legitima termer det drabbar. Individuellt tillägg tills flera
--      institutioner testats — sedan omvärdera regel.
-- =============================================================================

-- ─── 1. Dölj 'uncategorized' i panelens topic-fördelning ─────────────────────

create or replace function public.map_institution_detail(p_name text)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  with inst_articles as (
    select distinct
      a.id,
      a.topic,
      a.keywords,
      coord.country
    from public.articles a
    cross join lateral jsonb_to_recordset(a.institution_coords)
      as coord(name text, country text)
    where a.irrelevant is not true
      and a.institution_coords is not null
      and jsonb_array_length(a.institution_coords) > 0
      and coord.name = p_name
  ),
  base_stats as (
    select
      count(*)::int as article_count,
      max(country)  as country
    from inst_articles
  ),
  topic_counts as (
    select topic, count(*)::int as n
    from inst_articles
    where topic is not null
      and topic <> 'uncategorized'   -- döljs i panelen, säger inget
    group by topic
    order by n desc, topic asc
    limit 10
  ),
  keyword_counts as (
    select kw.w as keyword, count(*)::int as n
    from inst_articles ia,
         lateral unnest(coalesce(ia.keywords, array[]::text[])) as kw(w)
    where kw.w is not null
      and length(trim(kw.w)) > 0
      and not exists (
        select 1 from public.openalex_concept_blocklist b
         where b.keyword = lower(kw.w)
      )
    group by kw.w
    having count(*) > 1
    order by n desc, kw.w asc
  )
  select jsonb_build_object(
    'name',          p_name,
    'country',       (select country from base_stats),
    'article_count', (select article_count from base_stats),
    'topics', coalesce(
      (select jsonb_agg(
        jsonb_build_object(
          'topic', topic,
          'count', n,
          'share', case when (select article_count from base_stats) > 0
                        then round(n::numeric / (select article_count from base_stats), 4)
                        else 0 end
        )
      ) from topic_counts),
      '[]'::jsonb
    ),
    'keywords', coalesce(
      (select jsonb_agg(
        jsonb_build_object('keyword', keyword, 'count', n)
      ) from keyword_counts),
      '[]'::jsonb
    )
  )
$function$;

grant execute on function public.map_institution_detail(text) to anon, authenticated, service_role;


-- ─── 2. Utöka blocklistan med Title Case-koncept observerade i Örebro-data ──

insert into public.openalex_concept_blocklist (keyword) values
  ('meal'),                                       -- OpenAlex-koncept, för generisk
  ('organic food and agriculture'),
  ('culinary culture and tourism'),
  ('sensory analysis and statistical methods')
on conflict (keyword) do nothing;


-- =============================================================================
-- Verifiering (efter apply):
--
--   -- 1. uncategorized borta från Örebro-panelen?
--   select public.map_institution_detail('Örebro University') -> 'topics';
--   -- expect: ingen entry med topic='uncategorized'
--
--   -- 2. Blocklist växt till 30 rader?
--   select count(*) from public.openalex_concept_blocklist;  -- expect 30
--
--   -- 3. De fyra observerade filtreras nu bort?
--   select public.map_institution_detail('Örebro University') -> 'keywords';
--   -- expect: inga entries med "Meal", "Organic Food and Agriculture" etc
--
-- FÖR FRAMTIDA UNDERSÖKNING (om regeln senare motiveras):
--
--   Kandidater för Title Case-filtret från alla institutioner:
--   select distinct kw.w
--     from public.articles a,
--          lateral unnest(a.keywords) as kw(w)
--    where a.irrelevant is not true
--      and kw.w ~ '^[A-Z][a-z]+(\s+(and|of|in|for|the)\s+[A-Z][a-z]+|\s+[A-Z][a-z]+)+$'
--      and not exists (
--        select 1 from public.openalex_concept_blocklist b
--         where b.keyword = lower(kw.w)
--      )
--    order by kw.w
--    limit 100;
-- =============================================================================
