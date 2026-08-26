-- =============================================================================
-- ORDER 176 (2026-08-26) — delta-logg per artikel + counts_by_year-snapshot
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN.
--
-- SYFTE (2026-08-26):
--
--   backfill-citation-counts.ts vet redan vilka rader som ändrat värde vid
--   varje körning, men den informationen kastas — bara aggregatet
--   articles_updated sparas i citation_updates_runs. Två saker byggs här:
--
--   1. public.citation_deltas — en rad per artikel-delta per körning.
--      Möjliggör query:er som "vilka artiklar rör sig snabbast senaste
--      30 dagarna" över godtycklig period.
--
--   2. public.articles.citations_by_year — JSONB-kolumn för OpenAlex-fältet
--      counts_by_year (array av {year, cited_by_count}). Ger acceleration
--      direkt utan att vänta på att delta-loggen fyllts flera veckor.
--
-- STORLEKSESTIMAT (citation_deltas):
--   ~3 500 rader/körning × 104 körningar/år = ~360 000 rader/år.
--   Rad+2 index ≈ 200 B → ~220 MB efter 3 år. Ingen partitionering behövs
--   på denna nivå; om produktions-observationer visar sig avvika (t.ex.
--   >10 000 delta/run) kan partitionering på observed_at införas då.
--
-- STORLEKSESTIMAT (citations_by_year):
--   ~200 B jsonb per artikel × 28 750 = ~6 MB. Trivialt.
--
-- SEMANTIK:
--   - INSERT sker inuti bulk_update_citation_counts-RPC:n (nästa migration).
--     Den läser articles.citation_count pre-UPDATE via CTE-snapshot, sedan
--     UPDATE:ar och INSERT:ar delta atomiskt i samma transaktion.
--   - old_count kan vara NULL — första gången en artikel observeras med
--     citation_count > 0 finns ingen "gammal" siffra.
--   - observed_at denormaliseras från run-tiden för att stödja punkt-index
--     på (observed_at desc) utan JOIN mot citation_updates_runs för perioda
--     "top movers"-queries.
--
-- GRANTS:
--   - service_role: INSERT + SELECT (backfill-scriptet skriver, framtida
--     panel-RPC:er läser via SECURITY DEFINER).
--   - authenticated: SELECT (framtida admin-UI / veckobrev-generering).
--   - anon: inget direkt. Panel-data exponeras genom SECURITY DEFINER-RPC
--     som bygger på articles + citation_deltas + citation_acceleration.
-- =============================================================================


-- ── articles.citations_by_year ──────────────────────────────────────────────
alter table public.articles
  add column if not exists citations_by_year jsonb;

comment on column public.articles.citations_by_year is
  'ORDER 176 (2026-08-26): OpenAlex counts_by_year — array av '
  '{year, cited_by_count}, typiskt 5-10 år tillbaka. Uppdateras av '
  'bulk_update_citation_counts när citation_count ändras. Läs via '
  'citation_acceleration() för normaliserad acceleration.';


-- ── citation_deltas ─────────────────────────────────────────────────────────
create table if not exists public.citation_deltas (
  id          bigserial primary key,
  article_id  uuid        not null references public.articles(id) on delete cascade,
  run_id      bigint      not null references public.citation_updates_runs(id) on delete cascade,
  old_count   integer,
  new_count   integer     not null,
  observed_at timestamptz not null default now()
);

comment on table public.citation_deltas is
  'ORDER 176 (2026-08-26): en rad per artikel-delta per backfill-körning. '
  'INSERT:as inuti bulk_update_citation_counts-RPC atomiskt med UPDATE. '
  'Frågas för "top movers"-queries över godtycklig period.';


-- Perioda punkt-scans ("delta senaste 30 dagarna"): (observed_at desc).
create index if not exists ix_citation_deltas_observed_at_desc
  on public.citation_deltas (observed_at desc);

-- Historik per artikel: (article_id, observed_at desc).
create index if not exists ix_citation_deltas_article_time
  on public.citation_deltas (article_id, observed_at desc);


-- ── Grants ──────────────────────────────────────────────────────────────────
grant select, insert on public.citation_deltas to service_role;
grant usage, select on sequence public.citation_deltas_id_seq to service_role;
grant select on public.citation_deltas to authenticated;


-- =============================================================================
-- VERIFIERING EFTER APPLY:
--
--   -- 1. Tabellen + kolumnen existerar:
--   \d public.citation_deltas
--   \d public.articles   -- citations_by_year ska finnas som jsonb, nullable
--
--   -- 2. Indexes på plats:
--   select indexname from pg_indexes
--    where schemaname='public' and tablename='citation_deltas'
--    order by indexname;
--   -- expected: citation_deltas_pkey,
--   --           ix_citation_deltas_article_time,
--   --           ix_citation_deltas_observed_at_desc
--
--   -- 3. Grants:
--   select grantee, privilege_type
--     from information_schema.role_table_grants
--    where table_schema='public' and table_name='citation_deltas'
--    order by grantee, privilege_type;
--   -- expected: service_role INSERT/SELECT, authenticated SELECT
--
--   -- 4. FK-cascade fungerar (test på throwaway-artikel):
--   -- (bygg inte i prod-DB; kör bara i staging om osäkert)
-- =============================================================================
