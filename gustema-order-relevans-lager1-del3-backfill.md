# ORDER — Lager 1 Del 3: keyword-backfill (Grupp B). FAS 1 DIAGNOS.
**Datum:** 2026-07-17
**Deploy-grupp:** B (egen deploy — massdataskrivning 13k, isolerad verifiering).
**Endast läsning + design. INGEN skrivning till articles än.**
**Grund:** deployplan §Grupp B, atgardsplan §2. Del 1+2 (Grupp A) redan deployad.

---

## STATUS 2026-07-17 (pausad här — återuppta utvilad)
Grupp A DEPLOYAD + verifierad PÅ TOPICS+KEYWORDS-GRUND (concepts→topics-bytet
klart). Del 1 (get_most_cited gate→ranking), Del 2 (framåt-fix + guard + merge)
— alla bevisade live, merge verifierad mot nya grunden. Del 3 EJ påbörjad.

**Grund-beslut LÅST:** topics + keywords (primär) + concepts som FALLBACK när
< MIN_TERMS (=4). Ren där topics+keywords räcker, concepts-brus bara i glesa
artiklar. Modul: _shared/openalex-terms.ts (gamla openalex-concepts.ts raderad).
Fallback är LÄST-verifierad men EJ empiriskt utlöst (0/5 i stickprov, alla var
≥4). Bevisas empiriskt när Del 3 kör mot 13k (glesa finns garanterat där).

**TVÅ SAKER ATT HANTERA I NÄSTA SESSION (före/under Del 3):**
1. MELLANSKIKT: artiklar som fick keywords under GAMLA concepts-koden (mellan
   första Grupp A-deploy och topics-bytet). Mät antal + brus-stickprov. Om få
   + lite brus → ignorera. Om många/tydligt brus → rensa om via nya logiken
   (de har DOI). Egen liten fråga, ej blockerande.
2. DEL 3 backfill (nedan) — mot topics+keywords-grunden.

## STRATEGIBESLUT 2026-07-18 (Anders induktiv-fråga → kombinerad väg)

**Anders fråga:** relevansbedömningen (Haiku/runSci) läser redan abstractet —
kan keywords genereras INDUKTIVT (rent, gastro-kontext) i stället för
DEDUKTIVT från OpenAlex (brus)? Utredning gav nyanserat svar:

**FYND:** Haiku genererar redan rena keywords (trending topp-15 = Haiku-termer,
noll brus). Men Haiku täcker BARA ~29% (3 762 av 13 094) — resten har för kort
abstract (<50 tecken) för meningsfull generering. Problemet "saknade keywords"
sammanfaller till stor del med "saknat abstract". OBS: 29% är PROXY via
sci_ko-predikat (3762 eligible), EJ direkt abstract-längd-mätning (abstract-
fältet ej exponerat för anon). VERIFIERA direkt innan bygge.

Source-split: scopus 5155, pubmed 89, openalex ~7850 (500-fel, uppskattat).
No-DOI-svans: 16 (OpenAlex når dem ej; Haiku kan om abstract).

**BESLUT (i princip, EJ exekverat): KOMBINERAD väg, ordning (b):**
1. Haiku FÖRST (induktivt) där abstract räcker (~3762) → rent, gastro-kontext,
   uppfyller Anders princip vid källan.
2. OpenAlex FALLBACK bara för dem Haiku inte kunde nå (~9332 med DOI) →
   brusigt, render-filter hanterar vid visning.
3. Titel-bara för no-DOI-no-abstract-svansen → accepterad lucka.
Ordning (b) inte (a): Haiku-först ger rent där möjligt, brus bara där nödvändigt.
(a) vore OpenAlex-först = alla får brus + 3762 får Haiku ovanpå = sämre.

**SINGLE-SOURCE-KRAV (lärdom 4):** Extrahera runSci ur pipeline/index.ts:39-62
till _shared/haiku-sci.ts (ROLES + runSci + HaikuSciResult). Pipeline OCH ny
induktiv-backfill-fn importerar samma → identisk prompt/parsning, ingen drift.
Verifierat trivialt extraherbart (inga supabase-klient-beroenden i Haiku-anropet).

**TAKT:** pipeline-cron EJ i git (dashboard-satt, lärdom 7). sci_takt_1h=8 →
långsamt. Kostnadsgate (TRIAD_ENABLED) gäller SONNET, ej Haiku → sci-takt kan
skalas utan kostnadsomskrivning. Alternativ: skala cron ELLER manuell
HTTP-trigger av induktiv-backfill-fn (~$3-6 för Haiku-only).

**ÖPPNA VERIFIERINGAR FÖRE BYGGE (nästa session):**
1. Abstract-längd DIREKT (service_role/fn, ej proxy): hur många av 13094 har
   verkligen abstract >50 (Haiku-täckbara) vs korta? Bekräftar/korrigerar 29%.
2. Motsägelse att klargöra: alla 13110 hade has_core_claim=FALSE men
   relevance_sci=NULL. Är false bara vy-default för oprocessad artikel? (Troligt
   — betyder oprocessad, ej "körd+misslyckad". Bekräfta mot vy-definition.)
3. Source openalex-count gav 500 — kör om för exakt OpenAlex-täckning.

**EXEKVERINGSSKISS (efter verifiering, egen utvilad session — STÖRSTA bygget):**
extrahera haiku-sci.ts → bygg induktiv-backfill-fn (dryrun→live, guard, samma
prompt) → kör Haiku på ~3762 → OpenAlex-fallback på resten (render-filter) →
nollställ 498 fel-filtrerade → slutverifiering. Många nya delar; ej trött.

---



**Vad som hände:** Live-körning startade. Batch 1 (498 rader) skrevs — guard
VERIFIERAD i produktion (no-role −498, no-role-not-null +498, rollmärkta
OFÖRÄNDRAT 24977 = guard höll exakt). Men stickprov avslöjade filter-läcka
("Business" slank igenom), och Anders invändning öppnade en ARKITEKTURFRÅGA
som måste avgöras UTVILAD innan mer skrivs.

**ANDERS PRINCIP (viktig, styr beslutet):** En term är signal eller brus
beroende på RELATIONEN till artikelns övriga keywords/abstract/topic — inte
på termen själv. "Business" är signal i gastro-ekonomi-artikel (ekonomisk
hållbarhet = giltig tväraxel, lika relevant som ekologisk/social), brus i
logistik-artikel. Absolut blacklist MOTSÄGER denna princip (= score-som-gate
i ny form: irreversibelt beslut, grovt kriterium, fel tidpunkt).

**KRITISKT FYND — lager 3 viktar på FREKVENS, inte sällsynthet:** Verifierat
mot spec + deployad kod: keyword-nätverket/kartan använder nodstorlek =
antal artiklar med termen, edge = delade artiklar (redesign-spec:147,
landskap-2-spec:122, index.html:3548,1547). Det är MOTSATSEN till TF-IDF.
Så "spara rått + låt sällsynthet väga ner brett" (alt A) håller INTE — under
frekvens-viktning FÖRSTÄRKS breda termer (Business = jättenod), inte vägs ner.
Assistenten antog TF-IDF felaktigt; specen säger frekvens. (Lärdom: det som
bara finns i samtal, ej i spec, finns inte.)

**ÖPPET ARKITEKTURBESLUT (nästa session, utvilad, med spec framför sig):**
Under frekvens-viktning behövs NÅGON filtrering (annars dominerar brett), men
den måste respektera Anders princip (bevara ämnesaxlar: business, marketing,
economics, nutrition, sustainability, psychology?, sociology?). Tre vägar:
1. KONTEXTUELLT FILTER — behåll bred term bara om gastro-ankare finns bland
   artikelns andra keywords/topic. Matchar Anders princip EXAKT. Kod-komplext,
   kräver gastro-vokabulär. Rätt på sikt.
2. KONSERVATIV BLACKLIST — filtrera bara RENA grundvetenskaper som ALDRIG är
   gastro-linser (chemistry, biology, physics, materials science, mathematics,
   statistics). Släpp ALLA ämnesaxlar igenom. Pragmatiskt "nu, förfina senare".
3. TF-IDF-OMBYGGE — ändra lager 3-viktning till sällsynthet, då fungerar
   spara-rått. Renast arkitektoniskt men river upp lager 3-design + kart-ombygge.
Rekommendation att väga: (2) nu för att komma vidare + (1) som riktig lösning
när lager 3 byggs. (3) om lager 3 ändå ska omdesignas.

**STÄDNING FÖRE OMKÖRNING:** 498 rader skrevs med fel-koncipierat filter
(absolut blacklist inkl Business). Ska nollställas (keywords=NULL för
no-role-populationen skriven ~live#1, 16:55-16:56Z) och köras om mot vald
arkitektur. Guard är idempotent men bara för NULL → måste nollställa först.
Verifiera antal före nollställning.

**LIVE-GATE:** BACKFILL_LIVE_ENABLED sattes till true för körningen. MÅSTE
stängas: supabase secrets unset BACKFILL_LIVE_ENABLED (annars kan anon trigga
mer skrivning). KOLLA att detta gjordes.

---

## TIDIGARE STATUS (topics+keywords-grund, filter — nu delvis överspelat)

Del 3 backfill är BYGGD, VERIFIERAD, och redo för live-körning. Pausad FÖRE
den oåterkalleliga 13k-skrivningen — den förtjänar fräscha ögon.

**Vad som är klart:**
- backfill-openalex-terms edge-fn deployad (kör i Supabase, läser service_role
  från miljön — löser nyckelformat-problemet som fällde lokalt Deno-script:
  gammalt JWT-format vs nya sb_secret_-modellen).
- Använder SAMMA openalex-terms.ts som daily-fetch (symmetri verifierad).
- BRUS-FILTER inlagt: NOISE_BLACKLIST (chemistry/biology/food science/materials
  science/medicine etc + paren-brus) filtreras FÖRE fallback räknar MIN_TERMS.
  Beslut: filter FÖRE skrivning (ej "skriv smutsigt + städa senare" — det var
  fel ordning, dubbelt arbete, cleanup-blir-sällan-av).
- Dry-run 2 (med filter) verifierad: bruset borta, snitt/median sjönk (tog bort
  utfyllnad ej substans), glesa-men-rena artiklar acceptabla (rena få termer
  slår brusiga många — undviker falska nätverkskopplingar).

**LIVE-KÖRNING (nästa session — EN ren operation):**
1. supabase secrets set BACKFILL_LIVE_ENABLED=true (om unset)
2. Loop: curl -X POST .../backfill-openalex-terms?live=true (anon för anrop,
   fn använder miljö-service_role internt). 500/anrop, ~26 anrop, ~20-25 min.
   Guard keywords IS NULL → idempotent, re-kör failade utan dubbelskrivning.
3. Stopp när updated=0 (population genombetad).
4. supabase secrets unset BACKFILL_LIVE_ENABLED (stäng gaten igen).
5. VERIFIERA: räkna keywords NOT NULL bland no-role → gick från ~0 till ~13k.
   Stickprov 20 backfillade: rena termer, rätt artikel, rollmärktas orörda.

**VARNING till nästa session:** Live-gaten öppnades för tidigt + en ofiltrerad
loop byggdes under kvällens slutfas — tecken på trötthet. Kör live UTVILAD,
verifiera filtret är kvar (dry-run 1 gång till före live om osäker), skriv sedan.

**SCRIPT MÅSTE SKRIVAS OM:** backfill-openalex-concepts.ts (otrackad på disk)
är byggd mot GAMLA concepts. Skriv om mot _shared/openalex-terms.ts
(topics+keywords + concepts-fallback < MIN_TERMS=4) INNAN körning. Kör INTE
gamla scriptet. Dry-run 100 först (fallback bevisas empiriskt där), sedan
13k med guard (keywords IS NULL, idempotent, batchat, returning).

---

## MÅL
De ~13 620 no-role-artiklar med DOI saknar keywords helt (0 av 13 628 har).
Re-fetcha OpenAlex concepts/topics per DOI → filtrera (samma konstant som
Del 2: CONCEPT_LEVEL_MIN/SCORE_MIN i _shared/openalex-concepts.ts) → skriv
till TOMMA keywords-fält. Gratis (OpenAlex), noll Haiku.

Återanvänd Del 2:s hjälpfunktion (conceptsToKeywords) så nya och gamla
artiklar får IDENTISK keyword-behandling. Ingen ny tröskel-logik.

---

## DIAGNOS — rapportera, skriv inget

### 1. Målpopulationen exakt
- Bekräfta antal: no-role (score<5 alla 5 roller) + keywords tomt + HAR DOI.
- Hur många saknar DOI (kan ej re-fetchas, förblir keyword-lösa — acceptabelt)?
```sql
select
  count(*) as no_role_empty_kw,
  count(*) filter (where doi is not null and doi <> '') as has_doi,
  count(*) filter (where doi is null or doi = '') as no_doi
from articles
where irrelevant = false
  and (keywords is null or array_length(keywords,1) is null)
  and coalesce(relevance_sci_sensory_pro,0) < 5
  and coalesce(relevance_sci_culinary_pro,0) < 5
  and coalesce(relevance_sci_gastronomy_culture,0) < 5
  and coalesce(relevance_sci_hospitality_mgmt,0) < 5
  and coalesce(relevance_sci_educator_researcher,0) < 5;
```

### 2. OpenAlex batch-re-fetch — mekanik
- OpenAlex tillåter filter på flera DOI:er per anrop (filter=doi:X|Y|Z,
  upp till 50/anrop) + polite pool (mailto). Bekräfta batchstorlek + rate.
- ~13 620 / 50 = ~273 anrop. Realistisk körtid med polite delay?
- Var körs jobbet: engångs-Deno-script, edge-fn, eller SQL + pg_net? Föreslå
  det enklaste som är verifierbart isolerat (Grupp B-krav).

### 3. Skriv-guard (KRITISKT — 13k skrivning)
- Skriv ENDAST där keywords IS NULL (no-role tomma). Rör ALDRIG artiklar som
  redan har keywords (rollmärktas Haiku-keywords). Dubbel guard.
- Idempotent: kan köras om utan dubbelskrivning eller överskrivning.
- Batcha writes (t.ex. 500/UPDATE) — inte 13k enskilda. Med `returning` för
  räkning (lärdom 12).

### 4. Tröskel-utfall i skala (löser Del 2:s brus-fråga)
- Innan full körning: kör re-fetch på ETT stickprov (t.ex. 100 DOI:er),
  applicera CONCEPT_LEVEL_MIN=2/SCORE_MIN=0.3, visa resultatet:
  - Snitt keywords/artikel
  - Andel artiklar som får 0 keywords (concepts fanns men under tröskel)
  - Stickprov på faktiska keywords → ser Anders brus ("Constant (computer
    programming)") eller rent?
- Detta avgör om L>=2/0.3 håller eller ska skruvas till L>=3/0.4 INNAN 13k körs.
  (Del 2:s brus-observation avgörs här, i skala.)

### 5. DOI-lösa svansen
- De utan DOI: bekräfta att de är titel-sökbara ändå (Feed visar dem). Ingen
  åtgärd, bara notera antal.

---

## RAPPORTFORMAT
Målsiffror (punkt 1), re-fetch-mekanik + körtid (2), guard-design (3),
STICKPROVS-utfall med tröskel (4). INGEN 13k-skrivning förrän Anders sett
stickprovet och godkänt tröskeln.

## DEPLOY (efter godkänd diagnos)
Grupp B ensam: kör backfill-jobbet, stickprovs-verifiera 20-30 artiklar
EFTER (rätt artikel, meningsfulla keywords, rollmärktas orörda). Isolerat
från Grupp A så resultatet är otvetydigt.
