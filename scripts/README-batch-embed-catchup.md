# batch-embed-catchup.ts — bruksanvisning

Engångsscript: dra embedding-kön till 0 snabbare än
`generate-embeddings`-cronen (`*/30 * * * *`, 300/tick, ~14 400/dygn) hinner.

**När använda:** efter en batch-regen-triad-körning som lade till tiotusen nya
rader i embedding-kön. Cronens dygns-takt räcker inte utan halvdygns-latens
för Ask (embedding-lösa rader är osynliga för semantic-search).

**Kostnad:** ~$0.02/1M tokens (`text-embedding-3-small`). 12k rader ≈ $0.22.

---

## 1. Förkrav

**Deno** installerat:
```bash
brew install deno   # macOS
# eller: curl -fsSL https://deno.land/install.sh | sh
```

**Env-vars** (Anders kör själv — Claude rör aldrig dessa nycklar):
```bash
export OPENAI_API_KEY='<samma-nyckel-som-generate-embeddings-cronen>'
export SUPABASE_SERVICE_ROLE_KEY='<service-role-från-supabase-dashboard>'
export SUPABASE_URL='https://igmkzhdovyhbfgjomrsc.supabase.co'
```

---

## 2. Torrkör (räkna kön + estimera kostnad)

```bash
cd /Users/ashm/Downloads/gastro-research
deno run --allow-net --allow-env \
  scripts/batch-embed-catchup.ts --dry-run
```

Output:
- Antal rader i kön
- Estimerade tokens
- Estimerad kostnad i USD
- Antal chunks (rader/300)

---

## 3. Kör hela kön

```bash
deno run --allow-net --allow-env --allow-write \
  scripts/batch-embed-catchup.ts
```

Flöde:
1. Hämtar alla IDs+text-fält från kön via service_role (SB REST, paginerar 1000/sida)
2. Estimerar kostnad, visar `yes/no`-prompt innan OpenAI-anrop börjar
3. Per chunk (300 rader): bygger text via **samma invariant som edge-fn:en**
   (`title + core_claim + topic + 5 episteme`, join `' '`, slice 8000)
4. Anropar OpenAI `/v1/embeddings` (`text-embedding-3-small`)
5. Skriver `{embedding}` per rad via PATCH (parallellism 20 — samma som edge-fn:en)
6. Rapporterar `ok / openai_errors / db_errors`
7. Fel-IDs skrivs till `/tmp/batch-embed-<ts>-errors.jsonl`

**ETA:** 12k rader ≈ 42 chunks × ~2s OpenAI + ~2s DB-writes = **5–10 minuter**.

---

## 4. Kör bara N rader (sanity-test)

```bash
deno run --allow-net --allow-env --allow-write \
  scripts/batch-embed-catchup.ts --limit 300
```

Nyttig för första run: bekräfta att OpenAI-nyckel + service_role + text-invarianten
fungerar innan hela kön processas.

---

## 5. Vid fel — bara re-run

Script:et picker upp rader där `embedding IS NULL` — så re-run efter fixing
är säkert (redan-skrivna rader hoppas över automatiskt av SELECT-filtret).

Errored IDs i `/tmp/batch-embed-<ts>-errors.jsonl` är för utredning:
- `openai: 429` → rate-limit, vänta 60s och kör om
- `openai: 500` → backend-fel, kör om
- `db_error` → kolla loggarna för första felmeddelandet; troligen tillfälligt

---

## 6. Kritiskt: text-invariant måste matcha edge-fn:en

Script:et bygger `text` **exakt** som `generate-embeddings/index.ts` rad 55-60:

```ts
[a.title, a.core_claim, a.topic,
 a.episteme_sensory_pro, a.episteme_culinary_pro, a.episteme_gastronomy_culture,
 a.episteme_hospitality_mgmt, a.episteme_educator_researcher]
 .filter(Boolean).join(' ').slice(0, TEXT_SLICE)
```

Om edge-fn:en ändrar formatet: **uppdatera detta script i samma commit** —
annars driftar `semantic-search` mellan två embedding-generationer och
similarity-scores blir meningslösa över tid.

---

## 7. Interaktion med cronen medan script:et kör

**Säkert.** Både script:et och edge-fn:en tar från samma kö
(`embedding IS NULL AND episteme_sensory_pro IS NOT NULL`), men skrivningen
är per-ID PATCH. Om script:et hinner först: raden faller ur cronens
SELECT-fönster. Om cronen hinner först: samma. Ingen konflikt, ingen
dubbelskrivning, ingen tom loop.

Cron kan lämnas aktiv under körning.

---

## 8. Säkerhetsprinciper (samma som batch-regen-triad.ts)

- **OPENAI_API_KEY och SUPABASE_SERVICE_ROLE_KEY exponeras aldrig i chatten
  eller till Claude.** Anders kör hela script:et i sin egen terminal med
  nycklarna i sin egen miljö.
- Error-loggar hamnar i `/tmp/` (lokala, ej committade).
- Script:et gör DB-write via PATCH-per-rad — atomisk per rad, inga
  transaktioner över batch.
- Bekräftelseprompt (yes/no) innan OpenAI-anrop börjar.
