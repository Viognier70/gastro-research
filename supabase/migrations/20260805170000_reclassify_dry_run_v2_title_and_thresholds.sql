-- =============================================================================
-- reclassify_dry_run v2 — title-match + tre policy-varianter (2026-08-05)
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- Stickprovsanalys 2026-08-05 avslöjade två systemfel i v1:
--
--   1. ENA-TRÄFF-VINST: "Effect of fining agents on chemical composition and
--      sensory properties of apple cider" fick topic=food_psychology eftersom
--      "consumer preferences" var enda match. En kemi-studie, felklassad pga
--      score=1 räckte för att vinna topic-lottning.
--
--   2. FÖR SNÄV MATCH: "VOC fingerprinting" / "aroma profiling" matchade inte
--      trots att title bar "Volatile organic compounds" i klartext. v1 tittar
--      bara i keywords[]-arrayen.
--
-- v2 löser båda:
--   * Matchar även mot title (case-insensitive substring, som detectTopic gör).
--   * Räknar fyra scenarier parallellt så vi kan välja policy-tröskel efter
--     effekten på fördelningen i stället för på gissning.
--
-- FYRA SCENARIER (returnerade som SIDBY-SIDE-fördelning + moved-count):
--   a. keywords only, min 1 hit         — baseline (samma som v1)
--   b. keywords + title, min 1 hit      — isolerar effekten av title-add
--   c. keywords + title, min 2 hits     — isolerar effekten av strängare tröskel
--   d. keywords + title, min 2 hits ELLER (1 hit + ≥3 keywords totalt) — hybrid
--      "1 hit med kontext OK, 1 hit utan kontext icke OK"
--
-- SAMPLE innehåller topic-tilldelningen under ALLA fyra scenarier per rad,
-- så en läsare kan direkt jämföra där scenarier divergerar.
--
-- SIGNATUR OFÖRÄNDRAD: reclassify_dry_run(text, int) fungerar identiskt
-- som anrops-API men returnerar rikare JSONB. v1:s enklare {distribution:
-- [{before, after, delta}]} ersätts av v2:s {distribution: [{before,
-- after_a, after_b, after_c, after_d}]}. Ingen extern konsument, safe att
-- byta payload-form.
-- =============================================================================

create or replace function public.reclassify_dry_run(
  p_old_topic text,
  p_sample_n  int default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  v_result jsonb;
begin
  with base as (
    -- Target-population + kw_len för hybrid-tröskelvillkoret i scenario D.
    select
      a.id,
      a.title,
      a.topic as old_topic,
      a.keywords,
      coalesce(array_length(a.keywords, 1), 0) as kw_len
    from public.articles a
    where a.topic = p_old_topic
      and a.keywords is not null
      and array_length(a.keywords, 1) > 0
      and a.irrelevant is not true
  ),
  scored as (
    -- Per (article, topic) — dubbel poängkolumn: bara keywords vs keywords+title.
    -- HAVING kw_title_score > 0 eftersom scenarier B-D kräver minst en total match.
    -- Scenario A använder kw_score-filter separat.
    select
      b.id, b.title, b.old_topic, b.kw_len, tk.topic,
      count(*) filter (
        where exists (select 1 from unnest(b.keywords) as k(w) where lower(k.w) = lower(tk.keyword))
      )::int as kw_score,
      count(*) filter (
        where exists (select 1 from unnest(b.keywords) as k(w) where lower(k.w) = lower(tk.keyword))
           or (b.title is not null and position(lower(tk.keyword) in lower(b.title)) > 0)
      )::int as kw_title_score,
      array_agg(distinct lower(tk.keyword)) filter (
        where exists (select 1 from unnest(b.keywords) as k(w) where lower(k.w) = lower(tk.keyword))
           or (b.title is not null and position(lower(tk.keyword) in lower(b.title)) > 0)
      ) as matched_kw_title
    from base b
    cross join public.topic_keywords tk
    group by b.id, b.title, b.old_topic, b.kw_len, tk.topic
    having count(*) filter (
      where exists (select 1 from unnest(b.keywords) as k(w) where lower(k.w) = lower(tk.keyword))
         or (b.title is not null and position(lower(tk.keyword) in lower(b.title)) > 0)
    ) > 0
  ),
  ranked as (
    -- Window functions för snabb argmax per artikel. Två rankningar eftersom
    -- scenario A ordnar på kw_score och B-D ordnar på kw_title_score.
    select
      s.id, s.title, s.old_topic, s.kw_len, s.topic, s.kw_score, s.kw_title_score, s.matched_kw_title,
      row_number() over (partition by s.id order by s.kw_score       desc, s.topic asc) as rn_a,
      row_number() over (partition by s.id order by s.kw_title_score desc, s.topic asc) as rn_bcd
    from scored s
  ),
  picks as (
    -- En rad per artikel. Fyra kolumner för fyra scenariers vinnare, null om
    -- villkoret inte uppfylls (då hamnar de i 'uncategorized' i final-CTE:n).
    select
      b.id, b.title, b.old_topic, b.kw_len,
      max(case when r.rn_a   = 1 and r.kw_score       >= 1 then r.topic end) as w_a,
      max(case when r.rn_bcd = 1 and r.kw_title_score >= 1 then r.topic end) as w_b,
      max(case when r.rn_bcd = 1 and r.kw_title_score >= 2 then r.topic end) as w_c,
      max(case when r.rn_bcd = 1 and (r.kw_title_score >= 2
                                       or (r.kw_title_score = 1 and b.kw_len >= 3))
               then r.topic end) as w_d,
      max(case when r.rn_bcd = 1 and (r.kw_title_score >= 2
                                       or (r.kw_title_score = 1 and b.kw_len >= 3))
               then r.matched_kw_title end) as matched_d
    from base b
    left join ranked r on r.id = b.id
    group by b.id, b.title, b.old_topic, b.kw_len
  ),
  final as (
    select
      id, title, old_topic, kw_len,
      coalesce(w_a, 'uncategorized') as topic_a,
      coalesce(w_b, 'uncategorized') as topic_b,
      coalesce(w_c, 'uncategorized') as topic_c,
      coalesce(w_d, 'uncategorized') as topic_d,
      coalesce(matched_d, array[]::text[]) as matched_d
    from picks
  ),
  before_dist as (
    select topic, count(*)::int as c
    from public.articles
    where irrelevant is not true and topic is not null
    group by topic
  ),
  after_a as (
    select coalesce(f.topic_a, a.topic) as topic, count(*)::int as c
    from public.articles a
    left join final f on f.id = a.id
    where a.irrelevant is not true and a.topic is not null
    group by 1
  ),
  after_b as (
    select coalesce(f.topic_b, a.topic) as topic, count(*)::int as c
    from public.articles a
    left join final f on f.id = a.id
    where a.irrelevant is not true and a.topic is not null
    group by 1
  ),
  after_c as (
    select coalesce(f.topic_c, a.topic) as topic, count(*)::int as c
    from public.articles a
    left join final f on f.id = a.id
    where a.irrelevant is not true and a.topic is not null
    group by 1
  ),
  after_d as (
    select coalesce(f.topic_d, a.topic) as topic, count(*)::int as c
    from public.articles a
    left join final f on f.id = a.id
    where a.irrelevant is not true and a.topic is not null
    group by 1
  ),
  -- Alla topics som förekommer i något av leden — union för full outer join
  all_topics as (
    select topic from before_dist
    union select topic from after_a
    union select topic from after_b
    union select topic from after_c
    union select topic from after_d
  ),
  distribution as (
    select
      t.topic,
      coalesce(bd.c, 0) as before,
      coalesce(aa.c, 0) as after_a,
      coalesce(ab.c, 0) as after_b,
      coalesce(ac.c, 0) as after_c,
      coalesce(ad.c, 0) as after_d
    from all_topics t
    left join before_dist bd on bd.topic = t.topic
    left join after_a     aa on aa.topic = t.topic
    left join after_b     ab on ab.topic = t.topic
    left join after_c     ac on ac.topic = t.topic
    left join after_d     ad on ad.topic = t.topic
    order by abs(coalesce(ad.c, 0) - coalesce(bd.c, 0)) desc  -- störst rörelse i scenario D först
  ),
  sample as (
    -- Slumpade rader där någon scenariers tilldelning skiljer sig från old_topic.
    -- Ger användaren möjlighet att se WHERE-vart scenarier divergerar.
    select
      id,
      substring(title, 1, 140) as title,
      old_topic,
      kw_len,
      topic_a, topic_b, topic_c, topic_d,
      matched_d
    from final
    where topic_a != old_topic
       or topic_b != old_topic
       or topic_c != old_topic
       or topic_d != old_topic
    order by random()
    limit greatest(p_sample_n, 0)
  )
  select jsonb_build_object(
    'target_population', (select count(*) from final),
    'legend', jsonb_build_object(
      'a', 'keywords only, min 1 hit (baseline — matches v1)',
      'b', 'keywords + title, min 1 hit',
      'c', 'keywords + title, min 2 hits',
      'd', 'keywords + title, min 2 hits ELLER (1 hit AND >=3 keywords totalt)'
    ),
    'moved', jsonb_build_object(
      'a', (select count(*) from final where topic_a != old_topic),
      'b', (select count(*) from final where topic_b != old_topic),
      'c', (select count(*) from final where topic_c != old_topic),
      'd', (select count(*) from final where topic_d != old_topic)
    ),
    'to_uncategorized', jsonb_build_object(
      'a', (select count(*) from final where topic_a = 'uncategorized'),
      'b', (select count(*) from final where topic_b = 'uncategorized'),
      'c', (select count(*) from final where topic_c = 'uncategorized'),
      'd', (select count(*) from final where topic_d = 'uncategorized')
    ),
    'distribution', coalesce((select jsonb_agg(row_to_json(d)) from distribution d), '[]'::jsonb),
    'sample',       coalesce((select jsonb_agg(row_to_json(s)) from sample       s), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$function$;

revoke all on function public.reclassify_dry_run(text, int) from public;
grant execute on function public.reclassify_dry_run(text, int) to service_role;


-- =============================================================================
-- Användning (i SQL-editorn):
--
--   -- Full jämförelse mellan A/B/C/D + 20 sample-rader:
--   select public.reclassify_dry_run('gastronomy', 20);
--
--   -- Bara distribution (utan sample):
--   select public.reclassify_dry_run('gastronomy', 0);
--
--   -- Tabelliserad distribution jämför alla fyra scenarier:
--   select
--     value->>'topic' as topic,
--     (value->>'before')::int as before,
--     (value->>'after_a')::int as after_a,
--     (value->>'after_b')::int as after_b,
--     (value->>'after_c')::int as after_c,
--     (value->>'after_d')::int as after_d,
--     (value->>'after_d')::int - (value->>'before')::int as delta_d
--   from jsonb_array_elements(
--     (public.reclassify_dry_run('gastronomy', 0))->'distribution'
--   )
--   order by delta_d;
--
--   -- Sample med topic per scenario:
--   select
--     value->>'title' as title,
--     value->>'old_topic' as old,
--     value->>'topic_a' as a,
--     value->>'topic_b' as b,
--     value->>'topic_c' as c,
--     value->>'topic_d' as d,
--     value->'matched_d' as matched_d
--   from jsonb_array_elements(
--     (public.reclassify_dry_run('gastronomy', 20))->'sample'
--   );
--
--   -- moved + to_uncategorized för snabbjämförelse mellan scenarier:
--   select public.reclassify_dry_run('gastronomy', 0) #> '{moved}';
--   select public.reclassify_dry_run('gastronomy', 0) #> '{to_uncategorized}';
-- =============================================================================
