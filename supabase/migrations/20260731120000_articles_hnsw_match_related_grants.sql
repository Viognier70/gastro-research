-- =============================================================================
-- DB-fixar 2026-07-31: HNSW-index, match_related-omskrivning, read-grants
-- =============================================================================
-- Allt nedan är kört direkt mot prod 2026-07-31 och verifierat.
-- KÖR INTE OM MOT PROD — det är redan gjort. Denna fil är för git-paritet.
--
-- ⚠️  Punkt 1 (CREATE INDEX CONCURRENTLY) kan INTE köras via
--     `supabase db push`. CLI:t sveper migrationen i en transaktion och
--     CONCURRENTLY är otillåtet där. Applicera manuellt i SQL-editorn.
--     Punkt 2–3 klarar en transaktion.
--
-- =============================================================================
-- 1. HNSW-INDEX PÅ articles.embedding
-- =============================================================================
-- articles saknade helt vektorindex. Varje semantisk sökning tvingade Seq
-- Scan över 465 901 rader → 22–25 sekunder per fråga. PostgREST timeoutar
-- (default 15 s) långt innan → alla RPC-anrop från frontend som gick via
-- match_articles / match_related returnerade 57014 statement_timeout.
--
-- HNSW valdes över IVFFlat: bättre recall vid små K, ingen omträning krävs
-- när nya artiklar läggs till, och pgvector-defaulten (m=16, ef_construction
-- =64) räcker för vår storlek.
--
-- CONCURRENTLY så att index-bygget inte tar exklusivt lås på articles medan
-- pipeline fortsätter skriva. Bygget tog ~4 min mot 465k rader i prod.
-- =============================================================================

create index concurrently if not exists idx_articles_embedding_hnsw
  on public.articles using hnsw (embedding vector_cosine_ops);


-- =============================================================================
-- 2. match_related — OMSKRIVEN från sql till plpgsql
-- =============================================================================
-- LÄS DETTA INNAN DU RÖR EN VEKTORFUNKTION I DEN HÄR KODBASEN.
--
-- Att lägga till HNSW-indexet räckte INTE. Efter index-bygget körde
-- match_related fortfarande Seq Scan. Orsaken är två samverkande saker
-- som varsin är lätt att missa:
--
--   (a) Filter FÖRE order+limit blockerar HNSW.
--       Den gamla varianten (20260725120000) hade
--         where 1 - (a.embedding <=> seed.embedding) > p_floor
--         order by a.embedding <=> seed.embedding
--         limit p_k
--       pgvector's HNSW kan bara accelerera ren `order by <=> const limit N`.
--       Så snart WHERE innehåller ett similarity-uttryck faller planeraren
--       tillbaka till Seq Scan + Sort — hela poängen med indexet försvinner.
--
--   (b) `cross join seed` gör seed-embeddingen till en RUNTIME-kolumn,
--       inte en KONSTANT för planeraren. HNSW kräver en konstant vektor
--       på höger sida av <=>. Även utan (a) skulle detta ensamt räcka
--       för att blockera indexet.
--
-- Fix:
--   1. LANGUAGE plpgsql så vi kan hämta seed-embeddingen till en variabel
--      först. Variabeln parametreras in i den efterföljande queryn som ett
--      konstant värde — då kan HNSW ta över.
--   2. Ren `order by <=> v_seed limit p_k * 3` UTAN similarity-filter.
--      HNSW returnerar sina k*3 närmaste; vi filtrerar bort golv-underskott,
--      självreferens och irrelevant-vektorer efteråt på den lilla mängden.
--   3. p_k * 3 som headroom: HNSW är approximativ, och outer-filtren kan
--      äta rader. Faktor 3 räcker för p_k upp till ~50 utan att förlora
--      recall märkbart, mätt 2026-07-31.
--
-- Resultat: 25 142 ms → 25 ms (mätt via explain analyze före/efter).
--
-- Om du någon gång behöver ändra tillbaka till LANGUAGE sql: kontrollera
-- att seed-embeddingen inlineas som literal (via prepared statement /
-- SET LOCAL / vad-som-helst som gör den konstant för planeraren) OCH
-- att inget WHERE innehåller similarity-uttryck. Annars är du tillbaka
-- på 25 sekunder utan varning.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_related(
  p_article_id uuid,
  p_k          int   DEFAULT 10,
  p_floor      float DEFAULT 0.70
)
RETURNS TABLE(
  id         uuid,
  title      text,
  journal    text,
  year       text,
  similarity double precision
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_seed vector(1536);
BEGIN
  select embedding
    into v_seed
    from public.articles
   where id = p_article_id
     and embedding is not null;

  if v_seed is null then
    return;
  end if;

  return query
  with topk as (
    select
      a.id,
      a.title,
      a.journal,
      a.year,
      a.irrelevant,
      1 - (a.embedding <=> v_seed) as sim
    from public.articles a
    where a.embedding is not null
    order by a.embedding <=> v_seed
    limit p_k * 3
  )
  select t.id, t.title, t.journal, t.year, t.sim
    from topk t
   where t.id <> p_article_id
     and t.irrelevant is not true
     and t.sim > p_floor
   order by t.sim desc
   limit p_k;
END;
$function$;

grant execute on function public.match_related(uuid, int, float)
  to anon, authenticated, service_role;


-- =============================================================================
-- 3. GRANT + POLICY på articles för `authenticated`
-- =============================================================================
-- Egen regression från 20260725130000_security_rls_grants.sql: när
-- `grant all on all tables to anon, authenticated` revokerades fick
-- authenticated aldrig tillbaka SELECT på articles. Samtidigt gällde
-- policyn `Public can read articles` bara rollen {anon}. Nettoresultat:
-- inloggade Pro-användare fick noll rader ur match_articles / match_related
-- / articles_public medan utloggade fungerade — förvirrande felmönster
-- som tog dagen att spåra.
--
-- Två delar behövs:
--   (a) GRANT SELECT — utan detta får authenticated 401 innan RLS ens
--       utvärderas.
--   (b) Policyn måste inkludera {authenticated} — utan detta får
--       authenticated 0 rader efter RLS-utvärderingen även med granten.
-- =============================================================================

grant select on public.articles to authenticated;

drop policy if exists "Public can read articles" on public.articles;

create policy "Public can read articles"
  on public.articles for select
  to anon, authenticated
  using (true);


-- =============================================================================
-- Verifiering (körd 2026-07-31 efter apply):
--
--   -- 1. HNSW-index finns?
--   select indexname, indexdef
--     from pg_indexes
--    where schemaname='public' and tablename='articles'
--      and indexname='idx_articles_embedding_hnsw';
--   -- expected: 1 rad
--
--   -- 2. match_related använder indexet?
--   explain analyze
--     select * from public.match_related(
--       (select id from articles where embedding is not null limit 1),
--       10, 0.70);
--   -- expected: "Index Scan using idx_articles_embedding_hnsw" i planen,
--   --           total tid < 100 ms
--
--   -- 3. Grants + policy?
--   select privilege_type
--     from information_schema.role_table_grants
--    where grantee='authenticated' and table_schema='public'
--      and table_name='articles';
--   -- expected: SELECT
--
--   select roles, cmd, qual
--     from pg_policies
--    where schemaname='public' and tablename='articles'
--      and policyname='Public can read articles';
--   -- expected: roles={anon,authenticated}, cmd=SELECT, qual=true
-- =============================================================================
