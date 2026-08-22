> _Arkiv — skriven under namnet Gustema, nu Gusto Science._

# ORDER — keyword-kolumnbugg (fel kolumn läses)
**Datum:** 2026-07-15
**Typ:** Egen liten fix-session, lågrisk, hög produktpåverkan.
**Bör lagas oavsett om PCA-kartan byggs — påverkar HELA produkten.**

---

## Bakgrund (verifierat mot data 2026-07-15)

Två ARRAY-kolumner på articles med snarlika namn (lärdom 4):
- `keywords`       — **18 352 ifyllda, rik data** ("lactic acid bacteria",
  "red wine preferences" …). Pipeline skriver hit (u.keywords, rad 94).
- `claim_keywords` — **253 ifyllda, null på alla samplade rader.** Skräp.

Men: frontend LÄSER `claim_keywords` (FIELDS-strängar rad 2120, 3102,
4791, 5319) och `articles_public` exponerar BARA `claim_keywords`.
→ Produkten visar nästan inga keywords idag trots att 18 352 finns.
Tyst i månader (lärdom 5) — inget mätte det.

**Kanoniskt: `keywords`. `claim_keywords` ska bort.**

---

## FAS 1 — DIAGNOS/BEKRÄFTELSE (rapport, ingen ändring)

1. Bekräfta att inga ANDRA ställen skriver till `claim_keywords`
   (grep pipeline + alla edge-fns). Om något skriver dit: rapportera
   vad och varför innan vi dödar kolumnen.
2. Lista ALLA ställen frontend läser/renderar `claim_keywords`
   (inte bara FIELDS-strängarna — även rendering, filter, chips).
3. Kolla `pg_depend`: vad beror på articles_public? (Andra vyer,
   RPC:er som selektar den?) Så vi vet drop+create-omfånget.
RAPPORTERA. Ingen DDL än.

## FAS 2 — FIX (efter godkänd rapport)

### 2a. articles_public exponerar keywords (migration + CLI, ej SQL Editor)
- View kan ej ändra kolumn → drop + create (lärdom: kolla pg_depend först).
- Lägg till `keywords` i vyn. Behåll `claim_keywords` tills vidare
  (droppas i separat migration efter att frontend slutat läsa den —
  undvik att bryta live-frontend under deployglipan).
- Migration i git. `returning`/verifiering efteråt.

### 2b. Frontend byter claim_keywords → keywords
- Alla ställen ur Fas 1-punkt 2. FIELDS-strängar + rendering + ev. filter.
- Verifiera i RIKTIG browser (lärdom 3): Feed-kort och Explore visar nu
  riktiga keywords (fermentation, umami …) i stället för tomt.

### 2c. Städa claim_keywords (SENARE, egen migration)
- Först när 2b är live och verifierad: sluta all läsning bekräftad →
  drop column claim_keywords (migration, pg_depend-koll).
- INTE i samma commit som 2a/2b (deployordning: läsare bort först,
  kolumn sen).

---

## VERIFIERING
1. articles_public?select=keywords ger data (inte 400 42703).
2. Riktig browser: keywords syns på kort + Explore.
3. Ingen console-error, inget svalt i catch.
4. Räkna: hur många kort visar nu ≥1 keyword vs före (0-nära).

## KOPPLING
Detta är GATE B i gustema-landskap-2-spec.md — måste vara klart innan
kartans keyword-lager byggs. Men värdet är fristående: produkten får
tillbaka 18 352 keywords som legat osynliga.
