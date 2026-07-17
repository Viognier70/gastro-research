# ORDER — Navigation K2.2, Fas 2: bygg skelettet
**Datum:** 2026-07-16
**Scope:** BARA navigations-skelett. INTE Översiktens moduler (nästa session,
data-beroende). Ren frontend, index.html. Lågrisk (Fas 1 bekräftade: ingen
router, Syntheses noll inbound-länkar, deep-link ren addition).

---

## MÅL (ARK1 ur redesign-spec)
Fliksrad: **Översikt · Feed · Explore · Map**. Syntheses lämnar toppraden,
blir länkad subvy. Översikt blir default-landning, men byggs som SKELETT
(rubrik + platshållare) — modulerna kommer senare.

---

## STEG

### 1. Ny flik-ordning (rad 1189-1192)
Ersätt de fyra button-raderna med:
```
Översikt (data-view="oversikt")  ← ny, is-active
Feed     (data-view="feed")
Explore  (data-view="explore")
Map      (data-view="map")
```
Ta bort Syntheses-fliken (rad 1191) från topbaren.

### 2. Nytt view-block: view-oversikt (infoga före view-feed, ~rad 1196)
SKELETT — inga moduler än. Bara:
- Vy-container `<div id="view-oversikt">` (utan hidden = default synlig).
- Rubrik/eyebrow ("Översikt" / platshållartext "Din bevakning").
- En synlig platshållar-notis: "Framsidans moduler byggs härnäst"
  (så det är tydligt att skelettet är avsiktligt, inte trasigt).
- INGET data-anrop, ingen modul. Detta fylls i nästa session.

### 3. Feed: ta bort default-status
- `view-feed` får nu `hidden` (är inte längre default).
- Flytta `is-active` från Feed-knappen till Översikt-knappen.

### 4. Syntheses → subvy (behåll koden, flytta ingången)
- Behåll `view-syntheses`-diven (rad 1469-1480) och `loadSyntheses()`
  (rad 4595+) OFÖRÄNDRADE — bara fliken försvinner, inte funktionen.
- Lägg EN länk in till Syntheses från topbaren som sekundär ingång
  (t.ex. en liten "Synteser"-textlänk vid roll-chippet, ELLER i en
  meny) — INTE en huvudflik. Enklast nu: en diskret länk i topbaren
  som anropar `showView('syntheses')`.
- (Den permanenta ingången blir Översiktens syntes-modul senare —
  men den finns inte än, så vi behöver denna temporära länk så vyn
  inte blir oåtkomlig.)

### 5. showView(): utöka views-arrayen
- Lägg 'oversikt' i arrayen. Se till att 'syntheses' är kvar (nås via
  länken i steg 4).
- `window._appView` initial: 'feed' → **'oversikt'**.

### 6. Deep-link ?view= (ren addition, samma mönster som ?article=)
- På DOMContentLoaded: läs `?view=oversikt|feed|explore|map|syntheses`,
  anropa showView() med värdet om giltigt (annars 'oversikt').
- I showView(): `history.replaceState` uppdaterar `?view=` (behåll ev.
  `?article=` om det finns — kombinera, skriv inte över).
- Verifiera att ?article=<uuid> fortfarande fungerar (får inte brytas).

---

## VERIFIERING (riktig browser, lärdom 3)
1. Sidladdning → Översikt visas som default, skelett + platshållar-notis.
2. Klicka varje flik → rätt vy visas, is-active följer med.
3. Syntheses nås via sin länk, renderar synteserna som förr.
4. `?view=feed` i URL → landar på Feed. `?view=explore` → Explore.
5. `?article=<uuid>` fungerar fortfarande (deep-link till artikel).
6. Ingen console-error, inget svalt i catch.

## EFTER VERIFIERING
Visa mig i browser innan commit. Commit-scope: BARA navigation-skelettet.
Nästa session: Översiktens moduler (huvudnyhet, ticker, keywords,
samförfattare) — flera blockerade på datavalidering per redesign-spec.
