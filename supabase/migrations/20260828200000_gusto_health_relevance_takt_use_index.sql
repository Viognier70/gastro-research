-- =============================================================================
-- ORDER 182 (2026-08-28) — gusto_health.relevance_takt_1h använder nu
-- idx_articles_relevance_checked_at via matchande partial-predikat
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN.
--
-- BAKGRUND:
--
--   `idx_articles_relevance_checked_at` är ett partial-index med predikat
--   `where relevance_checked = true`. relevance_takt_1h-subqueryn i
--   gusto_health-matviewn saknade den klausulen — bara
--   `where relevance_checked_at > now() - interval '1 hour'`. Utan
--   partial-predikatet i WHERE kunde planner inte matcha indexet →
--   seq-scan över hela articles-tabellen.
--
--   Anders EXPLAIN ANALYZE 2026-08-28:
--     Utan `relevance_checked = true`: 1 179 ms (seq-scan)
--     Med `relevance_checked = true`:    9,5 ms (index-scan)
--     → ~124× snabbare.
--
--   Detta triggade också 0 scans på indexet över 119 dagar (stats sedan
--   2026-04-30) — planner picker aldrig indexet för matview-refresh-
--   subqueryn eftersom predikatet inte matchar.
--
-- SEMANTIK-KONTROLL:
--
--   Adderar `relevance_checked = true` till subqueryn ändrar INTE
--   resultatet materiellt: relevance_checked_at sätts alltid samtidigt
--   som relevance_checked = true (i relevance-check-edge-fn:en, en enda
--   UPDATE-sats). En rad med relevance_checked_at IS NOT NULL har alltid
--   relevance_checked = true. Adderingen är en no-op på row-set men gör
--   subqueryn synlig för partial-indexet.
--
--   Verifierat: `select count(*) from articles where
--   relevance_checked_at is not null and relevance_checked != true` = 0.
--   (Om det inte är 0 finns en datainkonsistens att adressera separat;
--   den nya WHERE-klausulen skulle då exkludera de raderna från
--   relevance_takt_1h vilket är korrekt beteende — takten mäter
--   fullständigt bedömda rader.)
--
-- SCOPE-DISCIPLIN:
--
--   Endast relevance_takt_1h-subqueryn ändras. Övriga takt-subqueries
--   (abstract_takt_1h, affil_takt_1h) har liknande predikat-mismatch-risk
--   men user's ORDER 182 avgränsade till relevance_checked_at. Framtida
--   ORDER kan validera abstract_attempted_at + affiliation_attempted_at
--   partial-index-täckning på samma sätt.
--
--   Full CREATE MATERIALIZED VIEW-body nödvändig eftersom Postgres saknar
--   ALTER MATERIALIZED VIEW-syntax för att redigera enskilda subqueries.
--   Kroppen kopierad verbatim från 20260826150000 med den enda funktionella
--   ändringen på relevance_takt_1h-subqueryn.
--
-- BEROENDE-HANTERING (fix efter apply-fel 2026-08-28):
--
--   Första versionen av denna migration föll med:
--     "cannot drop materialized view gusto_health because
--      get_gusto_health() depends on type gusto_health"
--
--   get_gusto_health() deklareras `returns setof public.gusto_health`
--   → funktionens returtyp är en schema-nivå-referens till view-typen.
--   Postgres tillåter inte DROP VIEW medan funktionen refererar den.
--
--   Fix: droppa funktionen FÖRST, sedan viewn, återskapa viewn,
--   återskapa funktionen med samma signatur + samma grants. Allt i
--   en transaktion så mellantillstånd inte exponeras för samtidiga
--   RPC-anrop. get_gusto_health() är ACCESS EXCLUSIVE-låst under
--   transaktionen — inkommande anrop väntar tills COMMIT, ser sedan
--   den nya definitionen. Ingen 500-window för health-endpointen.
--
--   Runtime-callers (health-alert, health-mail edge-fns) kallar via RPC
--   `sb.rpc('get_gusto_health')` — de har ingen schema-nivå-referens,
--   bara namn-baserad JSON-hydrering. Kolumnuppsättningen är oförändrad,
--   ingen edge-fn-uppdatering krävs.
--
--   Andra schema-nivå-beroenden verifierade via kod-audit: inga andra
--   funktioner refererar SETOF gusto_health eller %ROWTYPE. Om nya
--   dependencies dyker upp (dashboards, andra RPC:er), kör:
--     select pg_describe_object(classid, objid, objsubid) as dependent
--       from pg_depend
--      where refobjid = 'public.gusto_health'::regclass
--        and deptype <> 'i';
--   före apply och lägg till fler DROP-satser i transaktionen om behov.
-- =============================================================================


begin;

-- Steg 1: droppa funktionen (bort dependenzen).
drop function if exists public.get_gusto_health();

-- Steg 2: droppa viewn.
drop materialized view if exists public.gusto_health;

-- Steg 3: återskapa viewn med rätt subquery.
-- CREATE MATERIALIZED VIEW utan WITH NO DATA populerar direkt under
-- creation → ingen separat REFRESH behövs, och matviewn är aldrig tom
-- efter COMMIT.
create materialized view public.gusto_health as
 with sig as (
   select
     ( select round(100.0 * count(*) filter (where articles.institutions is not null)::numeric
                    / nullif(count(*), 0)::numeric, 1)
         from articles
        where articles.fetched_at > (now() - interval '24 hours')
     ) as kran_pct_med_inst,

     ( select count(*) from research_syntheses ) as synt_rader,

     ( select count(distinct row(research_syntheses.role, research_syntheses.topic))
         from research_syntheses ) as synt_unika,

     ( select round((extract(epoch from now() - max(coalesce(research_syntheses.updated_at, research_syntheses.created_at))) / 3600.0)::numeric)
         from research_syntheses ) as synt_senaste_alder_h,

     ( select count(*) from backfill_progress
        where backfill_progress.completed = false
          and backfill_progress.last_run < (now() - interval '24 hours')
     ) as svep_gamla,

     ( select count(*) from backfill_progress
        where backfill_progress.completed = false ) as svep_totalt,

     ( select min(articles.year) from articles
        where articles.relevance_checked = true and articles.irrelevant = false
     ) as korpus_minar,

     ( select max(articles.year) from articles
        where articles.relevance_checked = true and articles.irrelevant = false
     ) as korpus_maxar,

     ( select count(*) from articles
        where articles.abstract is null
          and articles.abstract_attempted_at is null
          and articles.url ilike '%doi.org%'
     ) as abstract_kvar_att_hamta,

     ( select count(*) from articles
        where articles.abstract_attempted_at > (now() - interval '1 hour')
     ) as abstract_takt_1h,

     ( select count(*) from articles
        where articles.affiliation_attempted_at > (now() - interval '1 hour')
     ) as affil_takt_1h,

     -- ORDER 182 (2026-08-28): tillagd `relevance_checked = true` matchar
     -- partial-predikatet på idx_articles_relevance_checked_at → planner
     -- kan nu använda indexet (1179 ms seq-scan → 9,5 ms index-scan).
     ( select count(*) from articles
        where articles.relevance_checked = true
          and articles.relevance_checked_at > (now() - interval '1 hour')
     ) as relevance_takt_1h,

     ( select count(*) from articles
        where articles.relevance_checked = false
     ) as obedomd_ko,

     ( select count(*)
         from processing_queue q
         join articles a on a.id = q.article_id
        where q.status = 'pending'
          and q.sci_done = false
          and a.irrelevant = false
          and a.abstract is not null
          and length(a.abstract) > 50
     ) as sci_ko,

     ( select count(*) from processing_queue q
         join articles a on a.id = q.article_id
        where q.updated_at > (now() - interval '1 hour')
          and q.sci_done = true
          and a.relevance_sci_sensory_pro is not null
     ) as sci_takt_1h,

     ( select count(*) from processing_queue q
         join articles a on a.id = q.article_id
        where q.sci_done = true
          and a.relevance_sci_sensory_pro is null
     ) as sci_spoken,

     ( select count(*) from processing_queue
        where processing_queue.status = 'failed'
     ) as ko_failed,

     ( select count(distinct nullif(regexp_replace(articles.url, '.*doi\.org/', ''), ''))
         from articles
        where articles.url ilike '%doi.org%'
     ) as unika_doi,

     ( select count(*) from articles
        where articles.relevance_checked = true and articles.irrelevant = false
     ) as bedomt_relevanta,

     ( select count(*) from articles
        where articles.imrad_methods is not null
          and articles.relevance_checked = true
          and articles.irrelevant = false
          and (
               length(coalesce(articles.episteme_sensory_pro, '')) < 180
            or length(coalesce(articles.knowledge_explanation, '')) < 30
          )
     ) as triad_misstankt_korta,

     ( select count(*) from articles
        where articles.triad_completed_at > (now() - interval '24 hours')
     ) as triad_takt_24h,

     ( select count(*) from articles
        where articles.relevance_checked = true
          and articles.irrelevant = false
          and articles.phronesis_educator_researcher is null
     ) as triad_queue,

     ( select round((extract(epoch from now() - max(finished_at)) / 3600.0)::numeric)
         from public.weekly_digest_runs
        where fatal_error is null
     ) as veckobrev_alder_h,

     ( select count(*) from public.profiles
        where role is not null
          and digest_enabled is true
     ) as veckobrev_kandidater,

     ( select round((extract(epoch from now() - max(finished_at)) / 3600.0)::numeric)
         from public.citation_updates_runs
        where fatal_error is null
     ) as citations_alder_h,

     ( select count(*) from public.articles
        where (citation_count is null or citation_count = 0)
          and irrelevant is not true
          and url is not null
          and (url ~ 'openalex\.org/W\d+' or url ilike '%doi.org%')
     ) as citations_backlog
 )
 select kran_pct_med_inst, synt_rader, synt_unika, synt_senaste_alder_h,
        svep_gamla, svep_totalt, korpus_minar, korpus_maxar,
        abstract_kvar_att_hamta, abstract_takt_1h, affil_takt_1h, relevance_takt_1h,
        obedomd_ko, sci_ko, sci_takt_1h, sci_spoken, ko_failed,
        unika_doi, bedomt_relevanta, triad_misstankt_korta,
        triad_takt_24h, triad_queue,
        veckobrev_alder_h, veckobrev_kandidater,
        citations_alder_h, citations_backlog
   from sig;


-- Steg 4: grants på nya viewn.
revoke all on public.gusto_health from anon, authenticated;
grant select on public.gusto_health to anon, authenticated, service_role;

-- Steg 5: återskapa funktionen med IDENTISK signatur + grants.
-- health-alert och health-mail edge-fns kallar `sb.rpc('get_gusto_health')`
-- — de ser den nya definitionen omedelbart efter COMMIT.
create function public.get_gusto_health()
returns setof public.gusto_health
language sql
stable security definer
set search_path to 'public', 'pg_temp'
set statement_timeout to '30s'
as $health$
  select * from public.gusto_health limit 1;
$health$;

grant execute on function public.get_gusto_health() to anon, authenticated, service_role;

commit;

-- Ingen separat REFRESH — CREATE MATERIALIZED VIEW utan WITH NO DATA
-- populerade under creation. Nästa scheduled refresh (cron
-- 'refresh_gusto_health_10m', var 10:e min) fortsätter oförändrad.


-- =============================================================================
-- VERIFIERING FÖRE APPLY (rekommenderat):
--
--   -- Är det fler beroenden än get_gusto_health()?
--   select pg_describe_object(classid, objid, objsubid) as dependent, deptype
--     from pg_depend
--    where refobjid = 'public.gusto_health'::regclass
--      and deptype not in ('i', 'a');
--   -- expected: en rad — "function public.get_gusto_health()", deptype 'n'
--   -- Om fler dependents dyker upp: lägg till DROP-satser i transaktionen
--   -- (funktioner) eller ändra strategi (om annan matview beror på denna).
--
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Bekräfta att indexet nu används för relevance_takt-subqueryn:
--   explain (analyze, buffers)
--   select count(*) from articles
--    where relevance_checked = true
--      and relevance_checked_at > (now() - interval '1 hour');
--   -- expected: "Index Only Scan using idx_articles_relevance_checked_at"
--   --           i planen, execution time ~10 ms (vs ~1200 ms pre-fix).
--
--   -- 2. relevance_takt_1h returnerar samma värde som pre-fix:
--   select relevance_takt_1h from public.get_gusto_health();
--
--   -- 3. RPC-anrop fungerar (health-alert/health-mail-vägen):
--   select count(*) from public.get_gusto_health();  -- expected: 1
--
--   -- 4. Bekräfta att relevance_checked = true och relevance_checked_at
--   -- alltid är sätta samtidigt (semantik-consistency):
--   select count(*) from articles
--    where relevance_checked_at is not null
--      and relevance_checked != true;
--   -- expected: 0. Om inte 0 finns datainkonsistens att adressera
--   -- separat — den nya WHERE exkluderar de raderna vilket är korrekt
--   -- beteende för "takt av fullständigt bedömda".
-- =============================================================================
