# Gustema — lägesrapport 2026-08-06

**Syfte:** En ny session ska kunna läsa in aktuellt läge utan att gräva.
Fokus: TRIAD-genereringens strategi (där mest missförstånd uppstår) +
dagens arbete + kvar före lansering.

**Föregående rapport:** `gustema-lage-2026-08-05.md` — läs den om
sammanhanget till kartan/reclassify saknas.

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
(översatt 2026-08-04 i commit `3ad96cd`).

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

## 3. Dagens arbete (2026-08-06)

Fyra spår färdiga idag ovanpå gårdagens sex tysta fel-fixar.

### 3.1 Topic-omklassificering genomförd

- **17 629 artiklar** lämnade falsk `topic='gastronomy'` (legacy-default
  före 2026-07-09)
- Ytterligare **1 506** från uncategorized-populationen
- **Metod:** keyword-matchning mot `topic_keywords`-tabellen, tre rundor
  utökningar (migrations `20260805140000`, `20260805150000`,
  `20260805160000`), apply i `20260805200000` (gastronomy) och
  `20260806150000` (uncategorized)
- **Fördelning nu:** food_science 8 455, uncategorized 6 013,
  fermentation_science 6 251, sensory_evaluation 2 951, flavor_science
  2 347, food_psychology 2 253
- `detectTopic` i `daily-fetch` läser nu `topic_keywords`-tabellen —
  gemensam källa, ingen dubblerad dict, nya keywords blir aktiva utan
  edge-fn-redeploy

### 3.2 Kartan ombyggd (commit 2 av redesignen)

- Färglegenden (fem påhittade familjer) **borttagen**
- **Ämnes-pills** under kartan: top 10 + Show all, klickbara, additivt
  urval, "× Clear (N)"-knapp. Institution passerar filtret om MINST EN
  artikel tillhör NÅGON vald topic (samma OR-semantik som Feed)
- **"My topics" borttagen** — filtrerade på QS-rank som proxy, meningslös
  affordance (41 av 33 818 artiklar har QS-rank)
- **Institutionspanel:** ämnesfördelning som stapelrad + klickbara nyckelord
  via `map_institution_detail()` och `map_institutions_by_keyword()`-RPC:er.
  Valda topic-pills markeras i stapelraden.
- **OpenAlex-konceptblocklista som tabell** (`openalex_concept_blocklist`)
  — 30 rader idag, utökbar via INSERT utan funktionskropps-ändring

Migration `20260806130000` gör den sista finjusteringen: döljer
`uncategorized` i institutionspanelens ämnesfördelning + utökar
blocklistan med fyra Title Case-koncept från Örebro-datan.

Kvarvarande: **Explore-samordning (commit 3, ej byggd)** — samma pills-
rad med samma klickbeteende i Explore-vyn.

### 3.3 TRIAD prompt v4 verifierad + deployad

- Verifierad mot **25-artikelstickprov:** 22 av 25 har fem unika
  Episteme-öppningar (v3 hade "The study establishes" i 21 av 21)
- Hedges namnger nu vad som är osäkert (regel 6)
- Jargong förklaras utan ordlista (regel 8)
- **Deployad till `triad-on-demand` OCH `triad-background`** — samma
  labeled-triad-prompt via shared modul, båda vägar generar konsekvent

### 3.4 TRIAD-väntevy

- **Roterande logotyp** i topbar (3s/varv linear) medan analysen kör
- **Relaterad forskning** — 3–5 kort från `match_related`-RPC, filtrerade
  på `year >= currentYear-2`, sorterade på similarity desc. Cachas på
  `window._relatedRows` så Related research-sektionen under TRIAD:en
  återanvänder svaret utan ny RPC.
- **Faslistan** degraderad till liten kursiv text under artiklarna
- Samma logo-rotation applicerad på Ask (parallellt med diamant-pulsen)

Adresserar den 60–75 s väntetid Sonnet-analysen tar — före ändringen fanns
bara en spinning knapp och en faslista.

### 3.5 Chronologisk commit-tabell

| Commit | Vad | Rot |
|---|---|---|
| `4d6fd61` | map institutionspanel-RPC + keyword-drill-down + concept-blocklista | Grundplåt för commit 2 av kart-redesignen |
| `fa5b9ef` | map: dölj uncategorized i panelen + utöka blocklistan | Örebro-panelen hade 9 av 36 uncategorized + fyra Title Case-koncept |
| `de7a8aa` | map commit 2: topic-pills + institutionspanel + keyword-drill-down | Färglegenden ersatt av pills; My topics + rank-filter borta |
| `2676ac1` | triad väntevy: roterande logo + recent research under analys | 60–75 s väntan behövde mer än en spinning knapp |
| `236cdb1` | text: HTML-entiteter i title/abstract/journal/authors | 305 rader hade `&lt;em&gt;`/`&amp;` — obrukbar APA-citering |
| `37972a9` | reclassify: apply-migration för uncategorized (7 519 rader) | topic_keywords-round 2/3 räckte men körde bara på gastronomy förra rundan |

**Deploy-status per 2026-08-06 kväll:**
- Alla commits pushade till `ux-ia-omstrukturering`-branchen
- Migrationer `20260806120000`, `20260806130000` applicerade
- Migration `20260806140000` (HTML-entity cleanup) — **väntar apply**
- Migration `20260806150000` (uncategorized reclassify) — **applicerad**,
  `refresh_map_mvs()` körd
- Edge-fn `daily-fetch` deployad med `cleanText` + `topic_keywords`-loader

---

## 4. Lärdom att skriva ned

**Sex tysta fel hittades 2026-08-04 → 2026-08-05.** Alla rapporterade
"succeeded" i cron-loggen.

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

**Ny lärdom idag:** HTML-entiteter i title/abstract/journal/authors var
tysta i 305 rader utan att någon räknare fångade det. Frontend
`_apaCleanTitle` strippade `<tag>` men inte `&lt;`/`&amp;`. Fix i tre lager
(DB-cleanup + daily-fetch normalisering + frontend defensive decode) —
samma trippelbälte-mönster som `topic_keywords` (tabell + edge-loader +
hardcoded fallback). Om en av tre havererar står de andra kvar.

---

## 5. Kvar före lansering

Länkar till L-numren i `gustema-lanseringschecklista.md` där de finns.

### 5A. Nya kända begränsningar (upptäckta 2026-08-06)

**A. OPENALEX AFFILIERINGSFEL** — verifierat mot deras API. Artiklar från
Restaurang- och hotellhögskolan vid Örebro universitet är i OpenAlex
registrerade under "Örebro University Hospital". Vår kod hämtar rätt,
källan har fel. Fyra artiklar korrigerade manuellt. Samma mönster finns
sannolikt för Karolinska, Uppsala, Lund — okontrollerat. Rapporterat till
OpenAlex.

**B. HTML-ENTITETER I TITLAR** — 167 med `&lt;`/`&gt;`, 138 med `&amp;`.
Förstör APA-citeringen. Ej åtgärdat.

**C. TECKENKODNING** — 16 författarrader och 4 titlar med ersättningstecken
(franska accenter brutna). Få, ej åtgärdat.

**D. UNCATEGORIZED 6 013** — nyckelorden fångar inte allt. Ärligt men stort.

### 5B. Blockerare / hög prio (oförändrat från 08-05)

- **Väktaren (byggd, ej implementerad)** — `gusto-vaktaren-spec.md`
  skriven 2026-07-13 beskriver EXAKT det problem som gav oss de sex
  tysta felen. Bumpa prioritet från "spec i backlog" till "före lansering".
  Utan Väktaren rapporterar cron "succeeded" tyst medan verkligheten dör.
- **L6.4 — TRIAD-eftermätning på nytt stickprov** — blockerare för Free-lansering.
  Kräver att batch-regenerering är klar (L6.3) och tröskelvärden nås.
- **L2.1 — Stripe end-to-end skarpt**
- **L2.2 — Free-flöde: Modell B (räkna visningar, 3/mån) byggd + verifierad**
- **L1.1b — service_role-nyckelrotation** kvarstår efter standardiseringen.
- **Nyckelrotation utökad** — Anthropic + service_role exponerades i
  terminal-sessioner. Rotera båda före publik lansering.
- **Merge till main** — prod kör kod från 13 juli. Snart tre veckors
  förbättringar ligger i `ux-ia-omstrukturering`-branchen utan att
  exponeras för användare.

### 5C. Bör före lansering

- **Explore-samordning (kartredesign commit 3, ej byggd)** — samma
  topic-pills-rad + samma klickbeteende i Explore-vyn. Kartans commit 2
  landade 2026-08-06; Explore står kvar med gamla mönstret.
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
- **Kartans mindre kvarvarande punkter:**
  - Coverage-texten är dynamiskt formulerad men behöver unit-check mot
    tratten innan launch
  - **Collaborations-linjer** ritas men noderna som inte är dot-refererade
    tappas — sidan visar färre linjer än datan säger
  - **Guldmarkering av valt land** saknas när country-sidebar öppen

### 5D. UX-dokumentationsgap (oförändrat)

Feed-kort, artikeloverlay, Ask-widget och all copy saknar spec. Buggar
som "författarkapning via `split(',')[0]`", `toggleImrad`-namnkollision,
My topics på QS-rank stod inte i strid med någon spec eftersom ingen fanns.

Vyernas *syfte* + Översikt + Map är dokumenterade i `gustema-redesign-spec.md`
och `gusto-map-omdesign.md`. Interaktionsdetaljer, kort-anatomi,
overlay-layout, Ask-flöde och all copy lever bara i git-historik + kod-
kommentarer.

**Kandidat:** utöka `gustema-redesign-spec.md` till vy-för-vy interaktions-
spec innan lansering. Utan det fortsätter chatt-beslut driva ändringar
som ingen kan kolla mot referens.

---

## 6. Snabblänkar

- **Aktiv branch:** `ux-ia-omstrukturering` (snart tre veckors förbättringar,
  ej mergad till main)
- **PostgREST-cap:** `docs/postgrest-caps.md` — läs INNAN nästa RPC-bygge
- **Backlog:** `docs/backlog.md` — map-RPC:erna som materialiserad vy
- **Prompt v4:** `supabase/functions/_shared/labeled-triad.ts`
- **Backfill-scripts:** `scripts/backfill-*.ts` (samma säkerhetsmönster:
  --dry-run default, /tmp-JSONL, sanity-cap, RPC-population)
- **Reclassify dry-run:** `scripts/reclassify-dry-run.ts`
  (`--old-topic=<topic> --only=a --sample=20`)
