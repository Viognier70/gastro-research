-- ============================================================================
-- Del 3-migrationen: TVÅ RPC-ändringar för induktiv Haiku-backfill.
--
-- 1. backfill_haiku_write() — NY — atomisk Metod B skrivning (articles +
--    processing_queue i en transaktion).
-- 2. stats_no_role_null_kw() — UTÖKAD — lägger till queue-split så vi kan
--    se hur många av Del 3-populationen som är i processing_queue och med
--    vilken status INNAN backfill-fn byggs (avgör om Metod B ska UPDATE:a
--    eller INSERT:a queue-rader).
-- ============================================================================


-- ============================================================================
-- 1. backfill_haiku_write() — atomisk skrivning av Haiku-inducerad backfill.
-- ============================================================================
--
-- Skriver Haiku-output (relevance_sci_*, keywords, core_claim, headline_en,
-- study_type) till articles OCH markerar processing_queue-raden (Metod B:
-- status='skipped' med orsak 'backfill_completed_awaiting_ondemand_triad')
-- i EN transaktion. Två separata UPDATE-anrop från edge fn kan drifta isär
-- vid nätverksfel; RPC:n hindrar det.
--
-- IDEMPOTENT: articles-UPDATE:n har WHERE relevance_sci_sensory_pro IS NULL
-- så second-run mot samma artikel skippar båda uppdateringarna. Returnerar
-- {article_updated, queue_updated, skipped} så edge fn kan logga korrekt.
--
-- METOD B-VAL:
-- Pipelinen (219-229) kör TRIAD Sonnet automatiskt när sci är klar OCH
-- max_score >= 5, UTAN kvot-gate. Om vi skriver sci-fält utan att markera
-- queue som färdig-hanterad, plockar pipeline artikeln, ser sci_done=false
-- lokalt (queue-flagga) → kör runSci IGEN → sedan TRIAD. Dubbel Haiku +
-- oavsiktlig $460 TRIAD-svep.
--
-- Metod B: status='skipped' + sci_done=true → pipeline hoppar. TRIAD sker
-- fortfarande via triad-on-demand (klick), som är kvoterad och cache:ad.
-- Ingen förändring av TRIAD_ENABLED.
--
-- SECURITY: security definer + grant execute till service_role (edge fn).
-- INTE grant till anon/authenticated — funktion skriver till articles
-- utan att gå via RLS och ska bara nås från serverside kod.

create or replace function public.backfill_haiku_write(
  p_article_id uuid,
  p_role_scores jsonb,
  p_keywords text[],
  p_core_claim text,
  p_headline_en text,
  p_study_type text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_article_updated int;
  v_queue_updated int;
begin
  -- Guard: skriv endast om Haiku ALDRIG körts. Idempotent utan explicit
  -- attempts-räkning — samma effekt som backfill-openalex-terms guard
  -- 'keywords IS NULL'.
  update articles set
    relevance_sci_sensory_pro         = coalesce((p_role_scores ->> 'sensory_pro')::int, 0),
    relevance_sci_culinary_pro        = coalesce((p_role_scores ->> 'culinary_pro')::int, 0),
    relevance_sci_gastronomy_culture  = coalesce((p_role_scores ->> 'gastronomy_culture')::int, 0),
    relevance_sci_hospitality_mgmt    = coalesce((p_role_scores ->> 'hospitality_mgmt')::int, 0),
    relevance_sci_educator_researcher = coalesce((p_role_scores ->> 'educator_researcher')::int, 0),
    keywords    = p_keywords,
    core_claim  = p_core_claim,
    headline_en = p_headline_en,
    study_type  = p_study_type
  where id = p_article_id
    and relevance_sci_sensory_pro is null;
  get diagnostics v_article_updated = row_count;

  if v_article_updated = 0 then
    return jsonb_build_object(
      'article_updated', false,
      'queue_updated',   0,
      'skipped',         true,
      'reason',          'already_written_or_missing'
    );
  end if;

  -- Metod B: markera queue-raden så pipeline hoppar. UPDATE på icke-existerande
  -- rad är no-op i Postgres (v_queue_updated=0 om artikeln aldrig var i queue).
  update processing_queue set
    status      = 'skipped',
    sci_done    = true,
    triad_done  = false,
    last_error  = 'backfill_completed_awaiting_ondemand_triad',
    updated_at  = now()
  where article_id = p_article_id;
  get diagnostics v_queue_updated = row_count;

  return jsonb_build_object(
    'article_updated', true,
    'queue_updated',   v_queue_updated,
    'skipped',         false
  );
end;
$function$;

grant execute on function public.backfill_haiku_write(uuid, jsonb, text[], text, text, text)
  to service_role;

revoke execute on function public.backfill_haiku_write(uuid, jsonb, text[], text, text, text)
  from public, anon, authenticated;


-- ============================================================================
-- 2. stats_no_role_null_kw() — UTÖKAD med queue-split.
-- ============================================================================
--
-- Ersätter 20260718100000-versionen med tillägg av queue-status-räknare:
-- queue_pending / queue_processing / queue_done / queue_failed / queue_skipped
-- + queue_absent (finns INTE i processing_queue alls).
--
-- Avgör Metod B-implementationen:
--   - Om många queue_pending → Metod B UPDATE:ar rader till 'skipped' (kritiskt
--     för att förhindra pipeline-plock efter backfill)
--   - Om många queue_absent → Metod B behöver INSERT nya rader ELLER kan
--     hoppa queue-hantering helt för dem (pipeline ser dem aldrig)

create or replace function public.stats_no_role_null_kw()
returns jsonb
language sql
security definer
stable
set search_path = public
as $function$
  with pop as (
    select id, abstract, source, relevance_sci_sensory_pro
    from articles
    where irrelevant = false
      and keywords is null
      and url ilike '%doi.org/%'
      and (relevance_sci_sensory_pro < 5 or relevance_sci_sensory_pro is null)
      and (relevance_sci_culinary_pro < 5 or relevance_sci_culinary_pro is null)
      and (relevance_sci_gastronomy_culture < 5 or relevance_sci_gastronomy_culture is null)
      and (relevance_sci_hospitality_mgmt < 5 or relevance_sci_hospitality_mgmt is null)
      and (relevance_sci_educator_researcher < 5 or relevance_sci_educator_researcher is null)
  ),
  no_doi_pop as (
    select id, abstract from articles
    where irrelevant = false
      and keywords is null
      and (url is null or url not ilike '%doi.org/%')
      and (relevance_sci_sensory_pro < 5 or relevance_sci_sensory_pro is null)
      and (relevance_sci_culinary_pro < 5 or relevance_sci_culinary_pro is null)
      and (relevance_sci_gastronomy_culture < 5 or relevance_sci_gastronomy_culture is null)
      and (relevance_sci_hospitality_mgmt < 5 or relevance_sci_hospitality_mgmt is null)
      and (relevance_sci_educator_researcher < 5 or relevance_sci_educator_researcher is null)
  ),
  queue_split as (
    select q.status, count(*) as n
    from pop p
    join processing_queue q on q.article_id = p.id
    group by q.status
  )
  select jsonb_build_object(
    'total_with_doi', (select count(*) from pop),
    'total_no_doi',   (select count(*) from no_doi_pop),

    -- (1) ABSTRACT-LÄNGDBUCKETS
    'abstract_null',                 (select count(*) from pop where abstract is null),
    'abstract_unavailable',          (select count(*) from pop where abstract = '[unavailable]'),
    'abstract_1_50',                 (select count(*) from pop where abstract is not null and abstract <> '[unavailable]' and length(abstract) between 1 and 50),
    'abstract_51_200',               (select count(*) from pop where length(abstract) between 51 and 200),
    'abstract_201_plus',             (select count(*) from pop where length(abstract) > 200),
    'abstract_gt_50_haiku_eligible', (select count(*) from pop where abstract is not null and abstract <> '[unavailable]' and length(abstract) > 50),

    -- (2) HAIKU-KÖRSTATUS
    'haiku_ran',   (select count(*) from pop where relevance_sci_sensory_pro is not null),
    'haiku_never', (select count(*) from pop where relevance_sci_sensory_pro is null),

    -- (3) SOURCE-FÖRDELNING
    'source_openalex',        (select count(*) from pop where source = 'openalex'),
    'source_scopus',          (select count(*) from pop where source = 'scopus'),
    'source_pubmed',          (select count(*) from pop where source = 'pubmed'),
    'source_semanticscholar', (select count(*) from pop where source = 'semanticscholar'),
    'source_crossref',        (select count(*) from pop where source = 'crossref'),
    'source_other_or_null',   (select count(*) from pop where source is null or source not in ('openalex','scopus','pubmed','semanticscholar','crossref')),

    -- (4) QUEUE-SPLIT (NYA 2026-07-18 — avgör Metod B implementation)
    'queue_pending',    coalesce((select n from queue_split where status = 'pending'), 0),
    'queue_processing', coalesce((select n from queue_split where status = 'processing'), 0),
    'queue_done',       coalesce((select n from queue_split where status = 'done'), 0),
    'queue_failed',     coalesce((select n from queue_split where status = 'failed'), 0),
    'queue_skipped',    coalesce((select n from queue_split where status = 'skipped'), 0),
    'queue_absent',     (
      select count(*) from pop p
      where not exists (select 1 from processing_queue q where q.article_id = p.id)
    ),

    -- No-DOI-svansen: abstract-status
    'no_doi_abstract_gt_50',         (select count(*) from no_doi_pop where abstract is not null and abstract <> '[unavailable]' and length(abstract) > 50),
    'no_doi_abstract_short_or_null', (select count(*) from no_doi_pop where abstract is null or abstract = '[unavailable]' or length(abstract) <= 50)
  );
$function$;

grant execute on function public.stats_no_role_null_kw() to anon, authenticated;
