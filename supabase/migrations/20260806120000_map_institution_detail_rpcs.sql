-- =============================================================================
-- Institutionspanelen + keyword-drill-down (2026-08-06)
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- LEVERANS I DENNA MIGRATION:
--   1. Tabell openalex_concept_blocklist — seedad med OpenAlex L0-koncept
--      + vanliga metod-brus-termer. Utökbar via INSERT (samma resonemang som
--      topic_keywords: en tabell överlever förändringar utan att röra
--      funktionskropparna).
--   2. RPC map_institution_detail(p_name) — panel-data för klickad institution:
--      artikelantal, ämnesfördelning (top 10), keyword-frekvenser (alla > 1
--      förekomst, sorterade). Server-side aggregat, ingen client-truncation.
--   3. RPC map_institutions_by_keyword(p_keyword) — klickbart nyckelord i
--      panelen filtrerar kartan till institutioner med samma nyckelord.
--      Returnerar textlista av institutionsnamn.
--
-- INGEN MV FÖR PER-INSTITUTION-DETAILS. Långsvans (Örebro 35 artiklar) gör
-- per-institution-MV till en jättetabell med tunga jsonb-fält och begränsad
-- vinst — RPC on-demand vid klick är bättre kostnad-nytta. Om det visar sig
-- långsamt för Cornell/Wageningen (hundratals artiklar) kan supportindex
-- läggas till senare.
-- =============================================================================

-- ─── 1. Concept blocklist ────────────────────────────────────────────────────

create table if not exists public.openalex_concept_blocklist (
  keyword text primary key
);

-- Seed: OpenAlex L0-koncept + vanliga metod-brus-termer. Alla lowercase för
-- direktjämförelse med lower(kw). Chemistry/Biology/Medicine/Environmental
-- science EXKLUDERADE — de har food-adjacenta sub-termer och blockeras
-- inte defensivt. Utöka via INSERT om nya koncept dyker upp.
insert into public.openalex_concept_blocklist (keyword) values
  ('mathematics'),
  ('physics'),
  ('computer science'),
  ('sociology'),
  ('psychology'),
  ('philosophy'),
  ('engineering'),
  ('business'),
  ('economics'),
  ('political science'),
  ('history'),
  ('geography'),
  ('materials science'),
  ('geology'),
  ('art'),
  ('law'),
  ('statistics'),
  ('machine learning'),
  ('data mining'),
  ('artificial intelligence'),
  ('bioinformatics'),
  ('anthropology'),
  ('linguistics'),
  ('software engineering'),
  ('algorithm'),
  ('programming')
on conflict (keyword) do nothing;

revoke all on public.openalex_concept_blocklist from public, anon, authenticated;
grant select on public.openalex_concept_blocklist to anon, authenticated, service_role;


-- ─── 2. RPC: map_institution_detail ─────────────────────────────────────────
--
-- Aggregerar per klickad institution:
--   - article_count: unika artiklar där institutionen finns i coords
--   - country: från coord.country (max — bör vara konsistent per institution)
--   - topics: top 10 [{topic, count, share}] sorterat på count desc
--   - keywords: alla med count > 1, filtrerade mot blocklistan, sorterade
--     count desc → keyword asc
-- =============================================================================

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

revoke all on function public.map_institution_detail(text) from public;
grant execute on function public.map_institution_detail(text) to anon, authenticated, service_role;


-- ─── 3. RPC: map_institutions_by_keyword ────────────────────────────────────
--
-- Klick på nyckelord i panelen — vem mer forskar på detta? Returnerar lista
-- av institutionsnamn (coord-havande, non-irrelevant) där MINST EN artikel
-- har keyword:t. Frontenden filtrerar kartan mot listan.
--
-- Case-insensitive exact match — samma som pills' topic-filter.
-- =============================================================================

create or replace function public.map_institutions_by_keyword(p_keyword text)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(jsonb_agg(name order by name), '[]'::jsonb)
  from (
    select distinct coord.name
    from public.articles a
    cross join lateral jsonb_to_recordset(a.institution_coords)
      as coord(name text)
    where a.irrelevant is not true
      and a.institution_coords is not null
      and jsonb_array_length(a.institution_coords) > 0
      and coord.name is not null
      and a.keywords is not null
      and exists (
        select 1 from unnest(a.keywords) as kw(w)
         where lower(kw.w) = lower(p_keyword)
      )
  ) t
$function$;

revoke all on function public.map_institutions_by_keyword(text) from public;
grant execute on function public.map_institutions_by_keyword(text) to anon, authenticated, service_role;


-- =============================================================================
-- Verifiering (efter apply):
--
--   -- 1. Blocklist:
--   select count(*) from public.openalex_concept_blocklist;  -- expect 27
--
--   -- 2. Panel-detail för känd institution:
--   select public.map_institution_detail('Örebro University');
--   -- expect: article_count ~35, topics top-10, keywords med count > 1
--
--   -- 3. Keyword-drill-down:
--   select jsonb_array_length(public.map_institutions_by_keyword('wine'));
--   -- expect: >0 institutioner
--
--   -- 4. Grants (alla ska ge true för anon):
--   select has_function_privilege('anon',
--     'public.map_institution_detail(text)', 'EXECUTE');
--   select has_function_privilege('anon',
--     'public.map_institutions_by_keyword(text)', 'EXECUTE');
--   select has_table_privilege('anon',
--     'public.openalex_concept_blocklist', 'SELECT');
--
-- OM RPC:erna är långsamma (>1 s för medelstor institution):
--   - Överväg supportindex: CREATE INDEX ... USING gin (institution_coords)
--     jsonb_ops — hjälper cross join lateral jsonb_to_recordset-filtret
--   - Alternativ: supporttabell article_institution (article_id, name) med
--     b-tree på name — undviker LATERAL helt vid klick, kostnad: en trigger
--     på articles-insert/update som håller supporttabellen synk
-- =============================================================================
