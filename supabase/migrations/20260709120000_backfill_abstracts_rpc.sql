-- =====================================================================
-- backfill-abstracts rebuild — attempted_at column + COALESCE-UPDATE RPC
-- =====================================================================
-- Same pattern as the affiliation-backfill (20260708130000):
--
--   articles.abstract_attempted_at timestamptz    ← set only on 200/404
--   backfill_abstracts_update(p_id, p_abstract)   ← one atomic UPDATE:
--                                                   attempted_at unconditional,
--                                                   abstract via COALESCE
--
-- Anders 2026-07-09:
--   243 155 rader står i abstract IS NULL efter att '[unavailable]'-
--   sentinelen tömts. Nya backfill-abstracts (OpenAlex → Crossref) betar
--   av kön; attempted_at säkerställer att transient-fel (429, timeout,
--   5xx) inte skriver flaggan så raden återkommer nästa tick. En rad som
--   fått attempted_at satt men fortsatt saknar abstract innebär att både
--   OpenAlex och Crossref svarat 200/404 utan användbar text — ingen
--   sentinel, bara ett bevis på att båda källorna prövats.
--
-- Dollar-taggning: '$fn$' istället för '$$' så SQL Editor inte biter i
-- pluggarna om vi någon gång copy-pastar in något som råkar innehålla
-- $$ i kroppen. CREATE och GRANT som separata statements.
-- =====================================================================

alter table public.articles
  add column if not exists abstract_attempted_at timestamptz;

create or replace function public.backfill_abstracts_update(
  p_id       uuid,
  p_abstract text default null
) returns void
language sql
security definer
set search_path = public
as $fn$
  update public.articles set
    abstract_attempted_at = now(),
    abstract              = coalesce(abstract, p_abstract)
  where id = p_id;
$fn$;

grant execute on function public.backfill_abstracts_update(uuid, text)
  to service_role;

notify pgrst, 'reload schema';

-- =====================================================================
-- Verification (run after apply):
--
--   -- 1. Kolumn finns
--   select column_name, data_type
--     from information_schema.columns
--    where table_schema='public' and table_name='articles'
--      and column_name='abstract_attempted_at';
--   -- expected: 1 row, timestamp with time zone
--
--   -- 2. RPC finns med rätt signatur
--   select proname, pronargs from pg_proc
--    where pronamespace='public'::regnamespace
--      and proname='backfill_abstracts_update';
--   -- expected: 1 row, pronargs=2
--
--   -- 3. service_role kan köra
--   select has_function_privilege('service_role',
--     'public.backfill_abstracts_update(uuid,text)',
--     'EXECUTE');
--   -- expected: t
-- =====================================================================
