# Backlog

Icke-akuta tekniska skulder + åtgärdsförslag. Prioriterat implicit av
ordning; toppen är nästa upp när tidsluckor öppnas.

---

## Map-RPC:erna: materialiserad vy + timmes-refresh

**Symptom (2026-08-02):**
- `map_institution_stats()` + `map_country_stats()` tar ~634 ms i DB
- Intermittenta timeouts vid sidladdning när flera RPC:er går parallellt
  (map + Feed sidebar + trending keywords etc)
- Kalkylen körs on demand vid varje map-view-öppning för alla anon-besökare

**Diagnos:**
- Aggregeringen är seq scan över 38 897 non-irrelevant articles med
  group by primary_institution (5-10k rader ut) resp group by country
  (~100 rader ut)
- 634 ms är gränsen mellan "kännbart" och "tåligt" när det körs seriellt;
  konsurrerande med andra queries i sidladdningsvågen så blir det värre
- Detta är precis läget där materialiserade vyer vinner: kalkylen är
  billig att lagra (några KB), dyr att beräkna, ändras långsamt (per
  daily-fetch-cadens)

**Lösningsförslag:**

```sql
-- Materialiserade vyer, en per stat-RPC
create materialized view public.map_institution_stats_mv as
select
  primary_institution as institution,
  mode() within group (order by country) as country,
  count(*)::int as article_count
from public.articles
where irrelevant is not true
  and primary_institution is not null
group by primary_institution;

create index on public.map_institution_stats_mv (institution);

create materialized view public.map_country_stats_mv as
select
  country,
  count(*)::int as article_count,
  count(distinct primary_institution)::int as institution_count
from public.articles
where irrelevant is not true
  and country is not null
  and primary_institution is not null
group by country;

create index on public.map_country_stats_mv (country);

grant select on public.map_institution_stats_mv to anon, authenticated, service_role;
grant select on public.map_country_stats_mv     to anon, authenticated, service_role;

-- RPC:erna byts till att läsa från MV:erna i stället för basetabellen.
-- Behåll returtypen (jsonb) för bakåtkompatibilitet med frontend.
create or replace function public.map_institution_stats()
returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
  from public.map_institution_stats_mv t
$$;

create or replace function public.map_country_stats()
returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
  from public.map_country_stats_mv t
$$;
```

**Refresh-cadens:**

pg_cron varje timme:

```sql
select cron.schedule('refresh_map_stats_1h', '0 * * * *', $$
  refresh materialized view concurrently public.map_institution_stats_mv;
  refresh materialized view concurrently public.map_country_stats_mv;
$$);
```

`concurrently` kräver unique index — lägg t.ex. `create unique index on
map_institution_stats_mv (institution)` (institution är unik per group by).
Utan `concurrently` blockeras läsning under refresh (dålig UX för anon
som slår i det ögonblicket).

**Förväntad effekt:**
- Query-tid från 634 ms → <5 ms per RPC
- Ingen timeoutrisk vid sidladdning
- Daglig backfill (~50-200 nya artiklar) syns senast 60 min efter insert
- Kostnad: två MV på några MB, en cron-job

**Notering:**
- `refresh materialized view concurrently` tar ~samma tid som en vanlig
  refresh (~1s för dessa storlekar) men blockerar inte läsare
- Om cron någon gång är trasig blir MV:erna stale; övervaka via
  `select last_refresh from pg_stat_all_tables where relname like
  'map_%_stats_mv'` eller lägg en health-signal
- Alternativ till pg_cron: trigger på articles-inserts som markerar
  MV:erna dirty + en periodic sweep. Överkill för timme-cadens.

**Diagnos-datum:** 2026-08-02, backloggad av Anders för att göra andra
öppna punkter först.
