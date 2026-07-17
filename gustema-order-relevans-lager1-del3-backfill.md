# ORDER — Lager 1 Del 3: keyword-backfill (Grupp B). FAS 1 DIAGNOS.
**Datum:** 2026-07-17
**Deploy-grupp:** B (egen deploy — massdataskrivning 13k, isolerad verifiering).
**Endast läsning + design. INGEN skrivning till articles än.**
**Grund:** deployplan §Grupp B, atgardsplan §2. Del 1+2 (Grupp A) redan deployad.

---

## STATUS 2026-07-17 (pausad här — återuppta utvilad)
Grupp A DEPLOYAD + verifierad (Del 1 get_most_cited gate→ranking, Del 2
framåt-fix + guard + merge — alla bevisade live). Del 3 EJ påbörjad.

## TVÅ OLÖSTA BESLUT INNAN DEL 3 BYGGS (avgör grunden)
1. **raw_data finns INTE** — bekräftat (två gånger idag). Concepts kan inte
   läsas lokalt; måste re-fetchas LIVE från OpenAlex per DOI (~273 anrop
   batch 50). Del 3-scriptet bygger på live-fetch, inte lokal parse.
2. **concepts → topics+keywords?** OpenAlex deprecerar `concepts`. Del 2
   (deployad) använder concepts → fungerar nu men döende grund. Sida-vid-sida
   på 5 artiklar visade: topics = få rena hierarkiska, keywords = precisa
   mellanting, concepts = många men brusiga ("Constant (computer programming)").
   ÖPPEN FRÅGA (nästa session): ger topics+keywords tillräckligt MÅNGA termer
   (~5-7) för keyword-nätverkets kopplingar, eller behövs concepts bredd
   (~10-15) trots bruset? KRÄVER: live OpenAlex-fetch på 5 artiklar med
   TERMANTAL per fält (concepts-filtrerat / topics / keywords / topics+keywords
   deduped). Anders väljer mot den datan.
   → Om topics+keywords räcker: byt grund. Då REVIDERAS Del 2 (skriv om
   _shared/openalex-concepts.ts mot topics+keywords, bygg om daily-fetch +
   pipeline, verifiera merge kvarstår) OCH Del 3 byggs mot samma. Tröskel-
   konstanten (L>=2/0.3) kan då FÖRSVINNA — topics/keywords är kuraterade,
   inget filter behövs. Löser Del 2:s brus-problem vid roten.
   → Om concepts behövs för volym: behåll, men vet att det dör; planera
   topics-migration separat.

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
