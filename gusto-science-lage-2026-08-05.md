# Gustema — lägesrapport 2026-08-05

**Syfte:** En ny session ska kunna läsa in aktuellt läge utan att gräva.
Fokus: TRIAD-genereringens strategi (där mest missförstånd uppstår) +
dagens arbete + kvar före lansering.

**Relaterade filer (djupdykning):**
- `gustema-lanseringschecklista.md` — den fullständiga blockerare-listan
- `gustema-prismodell-spec.md` — intäktsmodell + gate-logik
- `gustema-order-relevans-lager1-del3-backfill.md` — arkitektur-besluten
- `gustema-redesign-spec.md` — vy-nivå-design (glest täckt, se § 5)
- `docs/postgrest-caps.md` — kritisk regel om server-tak

---

## 1. Beslut som gäller

### TRIAD on-demand är primärstrategi — pipeline-kaskaden är blockerad

**Källa:** `gustema-order-relevans-lager1-del3-backfill.md:245-249`
(Del 3 slutresultat 2026-07-19):

> Backfill: 12 948 av 13 094 (99%) via induktiv Haiku (…) med Metod B
> queue-hantering (status='skipped', sci_done=true, triad_done=false,
> last_error='backfill_completed_awaiting_ondemand_triad').
> **Pipeline-TRIAD-kaskaden blockerad; TRIAD sker on-demand via klick.**

Pipeline skriver Sci-scores (billig Haiku) på allt, men Sonnet-TRIAD är
explicit spärrad från automatisk kaskadering. Kön är avsiktligt fylld med
kandidater för klick — inte för background-cron.

### Budget-cap 500/dygn — beslutad 2026-07-19

**Källa:** `gustema-order-relevans-lager1-del3-backfill.md:370-374` +
`gustema-prismodell-spec.md:86-87` + `scripts/README-batch-regen-triad.md:157`
+ SQL-kommentar i `20260722120000_ask_budget.sql:4`.

`TRIAD_DAILY_BUDGET = 500`, aktiverad i commit `aa6c368`.
~$17.50/dag Sonnet-max = ~$525/mån hard-cap. Cache-hits räknas ALDRIG
mot cappen. Vid cap-hit frigörs lock så artikel kan analyseras nästa dag.

### Community-delning — en generering ger alla framtida läsare tillgång

**Källa:** `gustema-order-relevans-lager1-del3-backfill.md:381-392`.

Kvot dras BARA vid ny Sonnet-generering, aldrig vid cache-hit. En Pro-users
klick på en o-cachad artikel skriver TRIAD permanent till DB — alla framtida
läsare (Free + Pro) läser samma cache utan att röra sina egna kvoter.
Detta är den viraliska mekaniken bakom överlay-textraden
"The analysis is saved permanently and shared with all future readers"
(översatt idag i commit `3ad96cd`).

### Pre-seed av cachen — lanseringsförutsättning nr 4

**Källa:** `gustema-prismodell-spec.md:130-133`.

> Generera TRIAD för topp ~500-1000 artiklar/roll så gratis-smaken
> (3 uppslag) träffar substans, ej tomma väggar. Utan detta: Free-user
> klickar → o-cachat → lås → ingen aha → ingen konvertering.

Population: **~2 500-5 000** (500-1000 × 5 roller). Utförs via
`scripts/batch-regen-triad.ts` (Anthropic Batches API, 50% rabatt).
INTE via triad-background-cronen.

### Engelska som grundspråk — i18n rivet 2026-08-04

**Källa:** commits `d12f45e` (riva språkstacken) + `3ad96cd` (svensk-strippen).

Beslut: TRIAD-data är på engelska, målgruppen arbetar på engelska,
översättningen var 10-15 % komplett och läckte fantom-buggar. `lang`-variabel,
T-ordbok, `t()`, `toggleLang`, 11 `lang==='sv'`-ternärer, språkknapp — allt
borttaget. `lang`-parameter behållen i `ask-synth` med dokumenterat varför
(i18n-kontrakt kvar server-side).

---

## 2. Öppen fråga — triad-background-cronens roll

**Status:** Odefinierad. Genererar ~41-48 analyser/dygn utan att någon
har bestämt varför.

**Fakta:**
- `TRIAD_DAILY_BUDGET = 500`, men actual throughput ≈ 48/dygn
  (cron var 30 min × 1 artikel/tick per `HARD_TIMEOUT_MS 100s + Sonnet 75s`).
- Primärstrategin (§ 1) säger on-demand — cronens roll är oklar.
- `gustema-lanseringschecklista.md:101-105` (L6.5) flaggar den som
  "kandidat-blockerare" men utan riktning.

**Två läsningar, beslut krävs:**

- **(a) Hålla jämna steg med inflödet.** Motiverat: framåtriktade backfill-
  jobb (commit `6d440e2`) börjar producera dagsfärskt inflöde från 7 kärn-
  tidskrifter. Utan bakgrundsjobb växer o-cachat-populationen monotont.
- **(b) Stänga av helt.** Motiverat: on-demand är primär; cachen ska seedas
  medvetet, inte genom blind bakgrunds-generering.

Ingen är dokumenterat rätt idag. Skriv ned valet och uppdatera
`gustema-prismodell-spec.md` eller L6.5 med det.

---

## 3. Dagens pipeline-fixar (2026-08-04 → 2026-08-05)

Kronologiskt, med commit-hash. Alla för att stänga tysta hål:

| Commit | Vad | Rot |
|---|---|---|
| `961538a` | daily-fetch: fyra distinkta räknare för saveArticle-rejections (skippedShortTitle, skippedRelevance, duplicateInDb, skippedUrlConflict) + kumulativ `total_fetched` | En "skipped_duplicate"-räknare dolde att isDuplicate-avvisningar var tysta i två dygn |
| `20260804140000` (migration) | `relevance_check_reason`-kolumn + `next_relevance_batch()` RPC + cleanup av 2 215 shorts som fastnat i kön sedan 12 juli | Kön hade två tolkningar av "kort abstract" |
| `20260804180000` (migration) | processing_queue orphan-cleanup (4 047 rader) + defensiv sweep i reset-stuck-cronen | Två familjer orphans: 2 200 abstract-guardhålet, 1 847 senare-irrelevant |
| `41f0365` | auto_queue_new_article: abstract-guard vid enqueue | Rader utan giltigt abstract enqueueades och blev orphans |
| `0b87029` + `f028ee3` | auto_queue_on_abstract_fill: UPDATE-trigger + dokumenterad ingen-catchup | INSERT-guarden skapade ett hål — backfill-abstracts fyllde utan att köa |
| `a39f9cb` | daily-fetch + backfill-affiliations: institution_openalex_ids skrivs, trasig geo-extract borta | `/works/`-svaret har INTE geo på nested institutions — tyst felkälla på båda ingångar |
| `5f43444` | 3-fas geokodning: migration + Fas 1/2-scripts | Backlog: 1 421 saknade ids, ~11 000 unika institutioner behöver geo |
| `2d92ab7` + `dd64735` + `b29a8b3` | map-vyn: server-side aggregat via RPC → materialiserad vy med daglig refresh | 20 994 coord-artiklar > 1000-cap → Sverige gick från 10 dots till 1 |
| `6d440e2` | backfill_progress.direction + 7 forward-jobb för kärntidskrifter + `from_publication_date`-filter | 2026 var nästan tomt (254 rader mot ~4 000 vid 2025-års takt); backlog-sopor bara bakåt |
| `da0d25d` | prompt-v4: namngivna hedges, öppningsvariation, jargong-brygga | v3 hade repeterande "The study establishes that..."-öppning, vaga hedges, oförklarad jargong |

**Deploy-status per 2026-08-05 kväll:** allt commitat + pushat.
Migrationer applicerade i SQL-editorn per hand.
Edge-funktioner deployade individuellt av dig.

---

## 4. Lärdom att skriva ned

**Sex tysta fel hittades på 24 timmar. Alla rapporterade "succeeded" i cron-loggen.**

I fyra av fallen mätte räknaren fel sak:
- `total_fetched` var senaste-tick-count, inte kumulativt → jobb med rörelse men noll skrivet såg identiska ut med jobb som "just kört"
- `skipped_duplicate` täckte bara upsert-race, inte isDuplicate-avvisningar → 92% rejection såg ut som normal drift
- `backfill-affiliations` rapporterade `updated` men skrev alltid `institution_coords: null` → resultat mättes inte, bara att en runda kördes
- `queue_new_article`-triggern gav status ok även när claim-predikatet nästa steg skulle avvisa raden → rader gick in i kön, blev orphans, ingen räknare noterade

**Regel för nya jobb (håll strikt):**
- Rapportera **framsteg**, inte bara att det kördes
- Räkna det som HAR HÄNT från källdatans perspektiv, inte antalet försök
- Ny räknare per rejection-orsak — aggregat räknare döljer förskjutningar
- Verifiera "succeeded"-signaler mot data ur den andra riktningen minst en gång per vecka

Detta är exakt behovet `gusto-vaktaren-spec.md` (2026-07-13) beskriver.
Väktaren är skriven men **inte byggd** — se § 5.

---

## 5. Kvar före lansering

Länkar till L-numren i `gustema-lanseringschecklista.md` där de finns.

### Blockerare / hög prio
- **Väktaren (byggd, ej implementerad)** — `gusto-vaktaren-spec.md`
  skriven 2026-07-13 beskriver EXAKT det problem som gav oss dagens sex
  tysta fel. Bumpa prioritet från "spec i backlog" till "före lansering".
  Utan Väktaren rapporterar cron "succeeded" tyst medan verkligheten dör.
- **L6.4 — TRIAD-eftermätning på nytt stickprov** — blockerare för Free-lansering.
  Kräver att batch-regenerering är klar (L6.3) och tröskelvärden nås.
- **L2.1 — Stripe end-to-end skarpt**
- **L2.2 — Free-flöde: Modell B (räkna visningar, 3/mån) byggd + verifierad**
- **L1.1b — service_role-nyckelrotation** kvarstår efter standardiseringen.
- **Nyckelrotation utökad idag** — Anthropic + service_role exponerades i
  terminal-sessioner denna vecka. Rotera båda före publik lansering.
- **Merge till main** — prod kör kod från 13 juli. Två veckors förbättringar
  ligger i `ux-ia-omstrukturering`-branchen utan att exponeras för användare.

### Bör före lansering
- **Kunskapsformer-modalen — motsägande definitioner.** SVG-etiketter säger
  Episteme = "symbolisk inramning (ritualer/värdskap)", kc-text säger
  Episteme = "the foundation — flavour chemistry, sensory physiology,
  IMRaD". Samma inkonsekvens för Phronesis. Läsaren ser båda ramverken.
  Innehållsbeslut, inte översättning.
- **Ask i Feed** — widgeten står ovanför Feed-artikellistan men filtrerar
  inte flödet. Antingen filtrera Feed efter en ställd fråga, eller flytta
  Ask till egen yta så den inte konkurrerar med artikelläsning.
- **L3.4 — OG-meta med föråldrade tal** ("5,200+ studies / 453,000+
  scanned"). Verkligt idag: 32 728+ / 466 908+. Uppdatera före publik
  delning på LinkedIn/X/FB.
- **Kartans kvarvarande punkter:**
  - Coverage-texten "2 389 av 29 166" är dynamiskt formulerad men matchar
    inte fullt ut siffrorna från tratten (unit-check innan launch)
  - **My topics-knappen** använder QS-rank som proxy — se
    `gusto-map-omdesign.md` som säger "QS-gaten togs bort med bibehållen rank
    i tooltip". Nuvarande implementering använder rank som filter.
  - **Collaborations-linjer** ritas men noderna som inte är dot-refererade
    tappas — sidan visar färre linjer än datan säger
  - **Guldmarkering av valt land** saknas när country-sidebar öppen
- **loadKnowledgeMap (Explore-vyn) har samma trunkering kartan hade** —
  visar 3 % av korpusen eftersom den client-side-aggregerar över det
  server-kapade slicet på 1 000 rader. Samma fix-mönster som map-MV:erna
  (RPC + materialiserad vy).

### UX-dokumentationsgap (nytt: se `docs/lage`-diskussion 2026-08-05)

Feed-kort, artikeloverlay, Ask-widget och all copy saknar spec. Dagens
buggar (författarkapning via `split(',')[0]`, `toggleImrad`-namnkollision,
My topics på QS-rank) stod inte i strid med någon spec eftersom ingen fanns.

Vyernas *syfte* + Översikt + Map är dokumenterade i `gustema-redesign-spec.md`
och `gusto-map-omdesign.md`. Interaktionsdetaljer, kort-anatomi,
overlay-layout, Ask-flöde och all copy lever bara i git-historik + kod-
kommentarer.

**Kandidat:** utöka `gustema-redesign-spec.md` till vy-för-vy interaktions-
spec innan lansering. Utan det fortsätter chatt-beslut driva ändringar
som ingen kan kolla mot referens.

---

## 6. Snabblänkar

- **Aktiv branch:** `ux-ia-omstrukturering` (två veckors förbättringar,
  ej mergad till main)
- **PostgREST-cap:** `docs/postgrest-caps.md` — läs INNAN nästa RPC-bygge
- **Backlog:** `docs/backlog.md` — map-RPC:erna som materialiserad vy
- **Prompt v4:** `supabase/functions/_shared/labeled-triad.ts`
- **Backfill-scripts:** `scripts/backfill-*.ts` (samma säkerhetsmönster:
  --dry-run default, /tmp-JSONL, sanity-cap, RPC-population)
