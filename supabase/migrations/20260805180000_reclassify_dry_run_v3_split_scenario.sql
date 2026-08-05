-- =============================================================================
-- reclassify_dry_run v3 — p_scenario-parameter, split för statement_timeout
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- v2 (20260805170000) beräknade fyra scenarier parallellt över 18 131 artiklar
-- × 212 keywords = 3.8M row-kombinationer i scored-CTE:n + fyra separata
-- after-scans. Timeoutade i SQL-editorn.
--
-- Diagnos av dyraste delarna:
--   1. TITLE-MATCHNINGEN i scored-CTE:n — 3.8M case-insensitive substring-
--      sökningar (position lower(kw) in lower(title)). Scenario A skippar
--      denna helt (bara array-jämförelse), så A ensam är ~10x snabbare.
--   2. FYRA AFTER-SCANS — varje after_a/b/c/d körde full scan över articles
--      (~466k rader non-irrelevant) med LEFT JOIN final. Kollapsas här till
--      en scan för 'all'-vägen.
--
-- v3-lösning:
--   * p_scenario-parameter ('a','b','c','d','all'). Default 'all' bevarar
--     v2-beteendet för när tid finns.
--   * När p_scenario != 'all' beräknas bara EN scoring-kolumn i scored,
--     EN winner-kolumn i picks, EN after-scan. Ger single-scenario-svar
--     i ~sekunder istället för minuter.
--   * När p_scenario = 'all' — samma logik som v2 men med kombinerad
--     after-scan (unnest(array[a,b,c,d]) i en pass).
--
-- SVARSFORMAT när p_scenario != 'all':
--   {
--     "scenario": "a"|"b"|"c"|"d",
--     "target_population": N,
--     "moved": M,
--     "to_uncategorized": U,
--     "distribution": [{topic, before, after}, ...],
--     "sample": [{title, old_topic, new_topic, matched}, ...]
--   }
--
-- SVARSFORMAT när p_scenario = 'all': identiskt med v2.
-- =============================================================================

create or replace function public.reclassify_dry_run(
  p_old_topic text,
  p_sample_n  int default 0,
  p_scenario  text default 'all'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  v_result jsonb;
  v_use_title boolean;
  v_min_hits int;
  v_hybrid boolean;
begin
  -- Normalisera scenario. p_scenario styr:
  --   v_use_title  — inkludera title-substring-match?
  --   v_min_hits   — minsta antal matchande keywords för att vinna topic
  --   v_hybrid     — om score=1 tillåts när kw_len >= 3
  if p_scenario = 'a' then
    v_use_title := false; v_min_hits := 1; v_hybrid := false;
  elsif p_scenario = 'b' then
    v_use_title := true;  v_min_hits := 1; v_hybrid := false;
  elsif p_scenario = 'c' then
    v_use_title := true;  v_min_hits := 2; v_hybrid := false;
  elsif p_scenario = 'd' then
    v_use_title := true;  v_min_hits := 2; v_hybrid := true;
  elsif p_scenario = 'all' then
    -- Fall through till separat 'all'-block nedan
    null;
  else
    raise exception 'p_scenario måste vara a, b, c, d eller all (fick: %)', p_scenario;
  end if;

  -- ─── SINGLE-SCENARIO PATH (a/b/c/d) ───────────────────────────────────────
  if p_scenario in ('a','b','c','d') then
    with base as (
      select id, title, topic as old_topic, keywords,
             coalesce(array_length(keywords, 1), 0) as kw_len
      from public.articles
      where topic = p_old_topic
        and keywords is not null
        and array_length(keywords, 1) > 0
        and irrelevant is not true
    ),
    scored as (
      select
        b.id, b.title, b.old_topic, b.kw_len, tk.topic,
        count(*) filter (
          where exists (select 1 from unnest(b.keywords) as k(w) where lower(k.w) = lower(tk.keyword))
             or (v_use_title and b.title is not null
                 and position(lower(tk.keyword) in lower(b.title)) > 0)
        )::int as score,
        array_agg(distinct lower(tk.keyword)) filter (
          where exists (select 1 from unnest(b.keywords) as k(w) where lower(k.w) = lower(tk.keyword))
             or (v_use_title and b.title is not null
                 and position(lower(tk.keyword) in lower(b.title)) > 0)
        ) as matched
      from base b
      cross join public.topic_keywords tk
      group by b.id, b.title, b.old_topic, b.kw_len, tk.topic
      having count(*) filter (
        where exists (select 1 from unnest(b.keywords) as k(w) where lower(k.w) = lower(tk.keyword))
           or (v_use_title and b.title is not null
               and position(lower(tk.keyword) in lower(b.title)) > 0)
      ) > 0
    ),
    ranked as (
      select s.*,
             row_number() over (partition by s.id order by s.score desc, s.topic asc) as rn
      from scored s
    ),
    picks as (
      select
        b.id, b.title, b.old_topic, b.kw_len,
        max(case when r.rn = 1
                  and (r.score >= v_min_hits
                       or (v_hybrid and r.score = 1 and b.kw_len >= 3))
                 then r.topic end) as w,
        max(case when r.rn = 1
                  and (r.score >= v_min_hits
                       or (v_hybrid and r.score = 1 and b.kw_len >= 3))
                 then r.matched end) as matched
      from base b
      left join ranked r on r.id = b.id
      group by b.id, b.title, b.old_topic, b.kw_len
    ),
    final as (
      select id, title, old_topic, kw_len,
             coalesce(w, 'uncategorized') as new_topic,
             coalesce(matched, array[]::text[]) as matched
      from picks
    ),
    before_dist as (
      select topic, count(*)::int as c
      from public.articles
      where irrelevant is not true and topic is not null
      group by topic
    ),
    after_dist as (
      -- En scan över articles, LEFT JOIN final, group by hypotetiskt topic
      select coalesce(f.new_topic, a.topic) as topic, count(*)::int as c
      from public.articles a
      left join final f on f.id = a.id
      where a.irrelevant is not true and a.topic is not null
      group by 1
    ),
    all_topics as (
      select topic from before_dist union select topic from after_dist
    ),
    distribution as (
      select
        t.topic,
        coalesce(b.c, 0) as before,
        coalesce(a.c, 0) as after,
        coalesce(a.c, 0) - coalesce(b.c, 0) as delta
      from all_topics t
      left join before_dist b on b.topic = t.topic
      left join after_dist  a on a.topic = t.topic
      order by abs(coalesce(a.c, 0) - coalesce(b.c, 0)) desc
    ),
    sample as (
      select id, substring(title, 1, 140) as title, old_topic, kw_len, new_topic, matched
      from final
      where new_topic != old_topic
      order by random()
      limit greatest(p_sample_n, 0)
    )
    select jsonb_build_object(
      'scenario', p_scenario,
      'target_population', (select count(*) from final),
      'moved',            (select count(*) from final where new_topic != old_topic),
      'unchanged',        (select count(*) from final where new_topic = old_topic),
      'to_uncategorized', (select count(*) from final where new_topic = 'uncategorized'),
      'distribution', coalesce((select jsonb_agg(row_to_json(d)) from distribution d), '[]'::jsonb),
      'sample',       coalesce((select jsonb_agg(row_to_json(s)) from sample s), '[]'::jsonb)
    ) into v_result;

    return v_result;
  end if;

  -- ─── ALL-SCENARIOS PATH (samma som v2 men med kombinerad after-scan) ──────
  with base as (
    select id, title, topic as old_topic, keywords,
           coalesce(array_length(keywords, 1), 0) as kw_len
    from public.articles
    where topic = p_old_topic
      and keywords is not null
      and array_length(keywords, 1) > 0
      and irrelevant is not true
  ),
  scored as (
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
    select s.*,
           row_number() over (partition by s.id order by s.kw_score       desc, s.topic asc) as rn_a,
           row_number() over (partition by s.id order by s.kw_title_score desc, s.topic asc) as rn_bcd
    from scored s
  ),
  picks as (
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
    select id, title, old_topic, kw_len,
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
  -- EN scan över articles för alla fyra scenarier via unnest av arrayer.
  -- Ger 4 rader per artikel × ~460k = ~1.8M istället för 4 separata scans.
  after_expanded as (
    select
      unnest(array['a','b','c','d']) as scenario,
      unnest(array[
        coalesce(f.topic_a, a.topic),
        coalesce(f.topic_b, a.topic),
        coalesce(f.topic_c, a.topic),
        coalesce(f.topic_d, a.topic)
      ]) as topic
    from public.articles a
    left join final f on f.id = a.id
    where a.irrelevant is not true and a.topic is not null
  ),
  after_by_scenario as (
    select scenario, topic, count(*)::int as c
    from after_expanded
    group by scenario, topic
  ),
  all_topics as (
    select topic from before_dist
    union
    select topic from after_by_scenario
  ),
  distribution as (
    select
      t.topic,
      coalesce(bd.c, 0) as before,
      coalesce(max(case when ab.scenario = 'a' then ab.c end), 0)::int as after_a,
      coalesce(max(case when ab.scenario = 'b' then ab.c end), 0)::int as after_b,
      coalesce(max(case when ab.scenario = 'c' then ab.c end), 0)::int as after_c,
      coalesce(max(case when ab.scenario = 'd' then ab.c end), 0)::int as after_d
    from all_topics t
    left join before_dist bd on bd.topic = t.topic
    left join after_by_scenario ab on ab.topic = t.topic
    group by t.topic, bd.c
    order by abs(coalesce(max(case when ab.scenario = 'd' then ab.c end), 0) - coalesce(bd.c, 0)) desc
  ),
  sample as (
    select id, substring(title, 1, 140) as title, old_topic, kw_len,
           topic_a, topic_b, topic_c, topic_d, matched_d
    from final
    where topic_a != old_topic or topic_b != old_topic
       or topic_c != old_topic or topic_d != old_topic
    order by random()
    limit greatest(p_sample_n, 0)
  )
  select jsonb_build_object(
    'scenario', 'all',
    'target_population', (select count(*) from final),
    'legend', jsonb_build_object(
      'a', 'keywords only, min 1 hit (baseline)',
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

revoke all on function public.reclassify_dry_run(text, int, text) from public;
grant execute on function public.reclassify_dry_run(text, int, text) to service_role;


-- =============================================================================
-- Användning (i SQL-editorn):
--
-- ETT SCENARIO I TAGET (snabbt, undviker timeout):
--   select public.reclassify_dry_run('gastronomy', 20, 'a');
--   select public.reclassify_dry_run('gastronomy', 20, 'b');
--   select public.reclassify_dry_run('gastronomy', 20, 'c');
--   select public.reclassify_dry_run('gastronomy', 20, 'd');
--
--   -- Bara aggregat, inget sample:
--   select public.reclassify_dry_run('gastronomy', 0, 'd');
--
-- ALLA FYRA PARALLELLT (v2-läge, kan timeouta):
--   select public.reclassify_dry_run('gastronomy', 20, 'all');
--
-- SNABB MOVED/UNCATEGORIZED-JÄMFÖRELSE UTAN ATT KÖRA 'all':
--   -- Kör a,b,c,d separat, plocka ut moved-siffran ur varje:
--   with s as (
--     select 'a' as sc, public.reclassify_dry_run('gastronomy', 0, 'a') as r
--     union all
--     select 'b', public.reclassify_dry_run('gastronomy', 0, 'b')
--     union all
--     select 'c', public.reclassify_dry_run('gastronomy', 0, 'c')
--     union all
--     select 'd', public.reclassify_dry_run('gastronomy', 0, 'd')
--   )
--   select sc,
--          (r->>'moved')::int as moved,
--          (r->>'to_uncategorized')::int as to_uncategorized
--   from s;
-- =============================================================================
