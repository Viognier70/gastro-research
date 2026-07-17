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

**INFLÖDE VERIFIERAT FRISKT 2026-07-17 (korrigering):** En felaktig slutsats
uppstod ("daily-fetch kör inte sedan igår") baserad på EN nyaste-artikel-
timestamp. Buckets-vy (artiklar per minut/timme) visade att daily-fetch KÖR
i sin normala PERIODISKA takt — inflödet är friskt, backfillen öser inte ur
läckande båt. Lärdom 1 igen: en datapunkt är inte en takt; buckets avslöjade
mönstret timestampen dolde. Merge-verifieringen var troligen giltig (post-
deploy-artiklar fanns). Del 3 EJ blockerad.

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
