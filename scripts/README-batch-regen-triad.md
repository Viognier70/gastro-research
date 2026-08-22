# batch-regen-triad.ts — bruksanvisning

Regenerera TRIAD-analyser för en lista artikel-IDs via Anthropic Batches API.
~50% kostnadsrabatt mot per-anrop, klart inom 24h.

Använder EXAKT samma prompt/parser/validator som edge-fn:erna genom att
importera `supabase/functions/_shared/labeled-triad.ts` direkt — inga
duplicerade kodvägar, den nya prompten (v4, 2026-07-23) används automatiskt.

---

## 1. Förkrav

**Deno** installerat:
```bash
brew install deno   # macOS
# eller: curl -fsSL https://deno.land/install.sh | sh
```

**Env-vars** (Anders kör själv — Claude rör aldrig dessa nycklar):
```bash
export ANTHROPIC_API_KEY='<din-anthropic-nyckel>'
export SUPABASE_SERVICE_ROLE_KEY='<service-role-från-supabase-dashboard>'
export SUPABASE_URL='https://igmkzhdovyhbfgjomrsc.supabase.co'
```

---

## 2. Generera ID-lista

Kör i Supabase SQL Editor och exportera som CSV, sedan konvertera till en id per rad.

**Alla SQL:er nedan har `and irrelevant is not true`** — sparar ~28% av batch-kostnaden och regenererar bara det som produkten faktiskt serverar (Feed filtrerar `irrelevant=is.false` överallt, verifierat 2026-07-23 via `b1484625` seafood-artikeln).

**För bara 9700 befintliga (v3-analyser att skriva över):**
```sql
select id
  from articles
 where triad_completed_at is not null
   and irrelevant is not true
 order by triad_completed_at;
```

**För full regenerering (befintliga + kö, minus irrelevant):**
```sql
select id
  from articles
 where irrelevant is not true
   and (
     episteme_sensory_pro is not null
     or (
       -- kandidatvillkor: minst en roll har relevans men saknar TRIAD
       (relevance_sci_sensory_pro         >= 5 and episteme_sensory_pro         is null) or
       (relevance_sci_culinary_pro        >= 5 and episteme_culinary_pro        is null) or
       (relevance_sci_gastronomy_culture  >= 5 and episteme_gastronomy_culture  is null) or
       (relevance_sci_hospitality_mgmt    >= 5 and episteme_hospitality_mgmt    is null) or
       (relevance_sci_educator_researcher >= 5 and episteme_educator_researcher is null)
     )
   );
```

Spara som t.ex. `/tmp/all-ids.txt` (en UUID per rad, inga citattecken/kommatecken).

**OBS:** Kandidatvillkoret ovan är en gissning av `triad_background_candidates`-RPC:ns filter (som är orphan, ej i git). Bekräfta med:
```sql
select pg_get_functiondef(oid)
  from pg_proc
 where proname = 'triad_background_candidates';
```
Justera SQL:en ovan om filtret skiljer sig.

**Bonus-radering (om du vill rensa TRIAD på redan-irrelevant-flaggade artiklar):**
```sql
-- Kolla först hur många det gäller — inkonsekvent state (TRIAD + irrelevant=true)
select count(*)
  from articles
 where episteme_sensory_pro is not null
   and irrelevant is true;
```
Detta är ett separat data-hygien-beslut — inte del av batch-regenereringen.

---

## 3. Dry-run: estimera kostnad utan att skicka

```bash
cd /Users/ashm/Downloads/gastro-research
deno run --allow-net --allow-env --allow-read \
  scripts/batch-regen-triad.ts --ids /tmp/all-ids.txt --dry-run
```

Output ger:
- Antal requests
- Estimerade input/output tokens
- Estimerad kostnad i USD (Batches-rabatt inräknad)

**Prissättning bakom estimatet:**
- Sonnet 4.6 normalpris: $3/M input, $15/M output
- Batches API: **50% rabatt** → $1.50/M input, $7.50/M output
- Räknar ~200 chars/request prompt-overhead + full abstract (upp till 2000 chars) → ~1500 input tokens per artikel
- Output-estimat: 15 fält × ~60 ord × 1.3 tokens/ord ≈ 1170 tokens; avrundar upp till 1400 för säkerhet

**Grov kostnadsstorlek** (verkliga tal från dry-run gäller):
- ~9700 befintliga (irrelevant exkluderade): ~$100–150
- ~36657 minus 28% irrelevant ≈ 26400 aktiva: **~$400** (inte $550, tidigare räkning inkluderade irrelevant)

**ETA:** Anthropic Batches processas "inom 24h" — vanligt är några timmar upp till en dag för batches i denna storleksordning. Script:et pollar var 60:e sekund och rapporterar `processing / succeeded / errored` counts löpande.

---

## 4. Skicka batch

```bash
deno run --allow-net --allow-env --allow-read --allow-write \
  scripts/batch-regen-triad.ts --ids /tmp/all-ids.txt
```

Flöde:
1. Läser IDs, dedupar, validerar UUID-format
2. Hämtar `title, abstract, insight` från Supabase i chunks (100 IDs per request)
3. Bygger requests via `buildTriadPrompt`
4. Visar estimat + **frågar `yes/no` innan submit** (skydd mot oavsiktlig $500-submit)
5. Submittar batch → skriver batch-id + IDs till statefil `/tmp/batch-triad-<id>.state.json`
6. Pollar status var 60:e sekund tills `processing_status='ended'`
7. Hämtar JSONL-results → per artikel: parse + validate + DB-skrivning
8. Rapporterar `ok / sonnet_error / parse_error / db_error`
9. Om fel: skriver `/tmp/batch-triad-<id>-errors.jsonl` för utredning

---

## 5. Om script:et avbryts (nätverk, laptop-sömn, etc.)

Batch-jobbet fortsätter på Anthropics sida oavsett. Använd statefil för att fortsätta:

```bash
# batch-id syns i statefilen /tmp/batch-triad-<id>.state.json
deno run --allow-net --allow-env --allow-read --allow-write \
  scripts/batch-regen-triad.ts --resume msgbatch_01ABC...
```

Scriptet börjar då direkt polla status + processar results när batchen är klar.

---

## 6. Vad att kontrollera efter körning

**Steg-för-steg-kontroll:**
1. Verifiera stickprov: hämta 5 slumpvisa artiklar från listan, jämför före/efter i browser eller SQL.
2. Kolla att inga fabriceringsmönster återkommer (sök `pH \d`, `\d+°C`, specifika ord ur din tidigare granskning).
3. Om `errored_ids` innehåller många parse-fel → tyder på att prompten tvingar fram inkonsistent output-format. Iterera prompten och kör om felen.
4. Kolla `duration_ms` och SQL: `select count(*) from articles where triad_completed_at > 'YYYY-MM-DD'` för att verifiera att alla ~36k har skrivits.

**Kända gränser:**
- Batches API tar upp till 24h. Räkna med att script:et pollar hela tiden.
- Anthropic-max: 100 000 requests per batch. 36 657 ryms i EN batch.
- Om batchen blir stor kan Supabase-DB-skrivningen ta 5-10 min extra (100 rader per PATCH-request).
- `TRIAD_DAILY_BUDGET`-konstanten i `triad-background/index.ts` (500/dag) räknar EJ mot detta script — vi går direkt till Anthropic, inte via edge-fn.

---

## 7. Säkerhetsprinciper

- **ANTHROPIC_API_KEY och SUPABASE_SERVICE_ROLE_KEY exponeras aldrig i chatten eller till Claude.** Anders kör hela script:et i sin egen terminal med nycklarna i sin egen miljö.
- Statefiler och error-loggar hamnar i `/tmp/` (lokala, ej committade).
- Script:et gör DB-skrivning via PATCH-per-artikel — atomisk per rad, inga transaktioner över batch.
- Bekräftelseprompt (yes/no) innan submit förhindrar oavsiktlig kostnad.
