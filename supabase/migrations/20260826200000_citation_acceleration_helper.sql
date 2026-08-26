-- =============================================================================
-- ORDER 176 (2026-08-26) — citation_acceleration hjälpfunktion
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN.
--
-- SYFTE:
--
--   OpenAlex counts_by_year för innevarande år är per definition ofullständigt
--   — vi är mitt i året. En artikel med 40 citeringar hittills 2026 (efter
--   ~2 månader) mot 180 under hela 2025 ser ut att bromsa (ratio 0.22), men
--   projicerat till helår är takten 40 / (2/12) = 240 → ratio 1.33 = accelerar.
--
--   Utan denna normalisering skulle en "top movers"-panel visa nästan alla
--   artiklar som "bromsande" varje januari — år-frac är då 0.03-0.05 och
--   even 5-10 tidiga citeringar blir hyperskalade.
--
--   Hjälpfunktionen kapslar in normaliseringen så anropande RPC:er (framtida
--   panel + veckobrev-generator) inte behöver upprepa logiken — eller värre,
--   glömma den.
--
-- SIGNATUR:
--   citation_acceleration(by_year jsonb, ref_date date DEFAULT current_date)
--   RETURNS numeric
--
-- SEMANTIK:
--   ratio = (cur_count / year_frac) / prev_count
--
--   där:
--     cur_count  = counts_by_year för år(ref_date), 0 om saknas
--     prev_count = counts_by_year för år(ref_date)-1, 0 om saknas
--     year_frac  = förfluten andel av innevarande år (leap-year-medveten)
--
--   Ratio > 1  → accelererar
--   Ratio = 1  → håller taktеn
--   Ratio < 1  → bromsar
--
-- NULL-RETUR (medveten):
--   - by_year saknas / är tom / inte array
--   - prev_count = 0 (nyskapad artikel utan förra-års-baseline;
--     ratio blir oändligt)
--   - year_frac < 0.05 (första ~18 dagarna av januari; projektionen
--     blir för volatil för att vara meningsfull — panelen visar då
--     bara artiklar med säker signal)
--
-- STABILITY:
--   STABLE — current_date-defaulten gör funktionen icke-IMMUTABLE. Om
--   framtida caller passar ref_date explicit och behöver IMMUTABLE-form
--   för uttrycksindex kan en separat wrapper skapas då.
--
-- GRANTS: EXECUTE till public. Ren beräkning på caller-supplied jsonb;
--   inga tabelldata läses; ingen data-läcka.
-- =============================================================================


create or replace function public.citation_acceleration(
  by_year  jsonb,
  ref_date date default current_date
)
returns numeric
language plpgsql
stable
as $function$
declare
  cur_year    int;
  cur_count   int     := 0;
  prev_count  int     := 0;
  year_frac   numeric;
  cur_annual  numeric;
begin
  if by_year is null
     or jsonb_typeof(by_year) <> 'array'
     or jsonb_array_length(by_year) = 0 then
    return null;
  end if;

  cur_year := extract(year from ref_date)::int;

  select coalesce((elem->>'cited_by_count')::int, 0)
    into cur_count
    from jsonb_array_elements(by_year) elem
   where (elem->>'year')::int = cur_year
   limit 1;

  select coalesce((elem->>'cited_by_count')::int, 0)
    into prev_count
    from jsonb_array_elements(by_year) elem
   where (elem->>'year')::int = cur_year - 1
   limit 1;

  cur_count  := coalesce(cur_count,  0);
  prev_count := coalesce(prev_count, 0);

  -- Utan förra-års-baseline går ingen meningsfull ratio att beräkna.
  if prev_count = 0 then
    return null;
  end if;

  -- Andel av innevarande år som förlöpt (leap-year-medveten). Dag 1 = 1/365
  -- eller 1/366; sista dagen på året = 1.0.
  year_frac := (ref_date - make_date(cur_year, 1, 1) + 1)::numeric
             / (make_date(cur_year + 1, 1, 1) - make_date(cur_year, 1, 1))::numeric;

  -- Skyddsvillkor: första ~18 dagarna i januari (year_frac < 0.05) ger så
  -- extremt volatila projektioner (5 tidiga citeringar × 20 → 100) att
  -- signal:brus blir oanvändbart. Returnera NULL istället.
  if year_frac < 0.05 then
    return null;
  end if;

  cur_annual := cur_count::numeric / year_frac;
  return round(cur_annual / prev_count::numeric, 3);
end
$function$;


comment on function public.citation_acceleration(jsonb, date) is
  'ORDER 176 (2026-08-26): normaliserad acceleration = projicerat innevarande-'
  'års citeringstakt / förra årets. Skalar innevarande år efter förfluten '
  'andel så januari inte visar universell inbromsning. NULL om by_year saknar '
  'förra året, prev = 0, eller year_frac < 0.05 (första ~18 dagarna).';

grant execute on function public.citation_acceleration(jsonb, date) to public;


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. NULL för tom/felformad input:
--   select public.citation_acceleration(null);                                -- NULL
--   select public.citation_acceleration('[]'::jsonb);                         -- NULL
--   select public.citation_acceleration('{"foo":1}'::jsonb);                  -- NULL
--
--   -- 2. NULL när förra året saknas:
--   select public.citation_acceleration(
--     '[{"year":2026,"cited_by_count":10}]'::jsonb,
--     '2026-08-26'::date
--   );  -- NULL (ingen 2025-baseline)
--
--   -- 3. Normaliserad ratio (2026-08-26 = ~65% in i året):
--   -- 40 hittills i år / 0.65 ≈ 61.5 årstakt
--   -- 61.5 / 180 föregående år ≈ 0.342
--   select public.citation_acceleration(
--     '[{"year":2026,"cited_by_count":40},{"year":2025,"cited_by_count":180}]'::jsonb,
--     '2026-08-26'::date
--   );  -- ≈ 0.342 (bromsar)
--
--   -- 4. Accelererar-fall (100 hittills mot 40 förra året):
--   select public.citation_acceleration(
--     '[{"year":2026,"cited_by_count":100},{"year":2025,"cited_by_count":40}]'::jsonb,
--     '2026-08-26'::date
--   );  -- ≈ 3.85 (accelererar hårt)
--
--   -- 5. Januari-skydd — år-frac < 0.05:
--   select public.citation_acceleration(
--     '[{"year":2026,"cited_by_count":5},{"year":2025,"cited_by_count":100}]'::jsonb,
--     '2026-01-10'::date
--   );  -- NULL (för tidigt på året)
--
--   -- 6. Full-år-fall (31 dec, ratio = actual/actual):
--   select public.citation_acceleration(
--     '[{"year":2026,"cited_by_count":50},{"year":2025,"cited_by_count":100}]'::jsonb,
--     '2026-12-31'::date
--   );  -- = 0.500 (year_frac = 1.0 → ingen scaling)
--
--   -- 7. Grants:
--   select has_function_privilege('anon',
--     'public.citation_acceleration(jsonb, date)', 'EXECUTE');   -- true
--   select has_function_privilege('authenticated',
--     'public.citation_acceleration(jsonb, date)', 'EXECUTE');   -- true
-- =============================================================================
