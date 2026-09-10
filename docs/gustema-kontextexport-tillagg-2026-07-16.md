> _Arkiv — skriven under namnet Gustema, nu Gusto Science._

# Kontextexport — TILLÄGG 2026-07-16 (RPC-adoption + navigation)
**Klistras in i gustema-kontextexport (§0 lärdomar, §3, §8).**
**Sessionen: redesign-genomgång (Feed/Översikt) + navigation K2.2 +
RPC-adoption (från ett rött 400-fel i konsolen).**

---

## Tillägg till §0 — LÄRDOMAR

### 13. CI-linten skyddar bara det som ligger i git.
`get_most_cited` bar ett droppat chip-namn (`relevance_sci_sommelier`)
och returnerade 400/42703 TYST i två dagar (13→16 juli). Linten
(`lint-role-columns.sh`) skannar bara HTML/JS i repo — RPC:n levde i
Supabase SQL Editor, utanför git, osynlig. Kombinerat med `catch(e){}`
i loadMostCited → "Citations loading…" för evigt, ingen synlig signal.
**Regel:** ALL funktionsdefinition (RPC/DDL) ska bo i git via migration.
Det som bara finns i SQL Editor finns inte (jfr lärdom 7) OCH skyddas inte
av linten. En audit av HELA populationen (lärdom 11) hittade 8 orphan-RPCer;
bara get_most_cited bar chip-namn, men alla 8 adopterades till git så nästa
kolumndropp kan grep:as först.

### (förstärkning av lärdom 4/5) — keyword-buggen hade TRE halvor.
Frontend-fixen 2026-07-15 (3608abc) lagade bara EN. get_most_cited OCH
get_trending_keywords läste båda dead `claim_keywords` (253 rader) i stället
för `keywords` (18 352) — osynliga för att de var RPCer utanför git. Alla tre
nu lagade (b5e76ee). Lärdom: när en namnbugg hittas, greppa HELA populationen
inkl. RPCer, inte bara koden i git.

---

## Tillägg till §3 — DENNA SESSIONS ARBETE

### Klart och verifierat (produktion, gusto.science)
- **Färgkonsolidering (4f2859b):** 3 parallella topic→färg-mappningar →
  EN shared const, 27 unika nyanser (alt. A: unik nyans inom 5 familjer),
  namn-städning (art_food→art_science, nutrition_science bort), uncategorized
  + fallback = neutral grå. Verifierad live: fermentation ≠ hospitality,
  inga kollisioner.
- **Navigation K2.2 (b5e76ee-serien):** Översikt = ny landning (skelett),
  Syntheses ut ur flikraden → subvy via showView(), ?view=-deep-link
  (kombineras med ?article=). Flikar: Översikt/Feed/Explore/Map.
- **RPC-adoption + fixar (b5e76ee):** 8 orphan-RPCer adopterade till git
  (migration 20260716120000). get_most_cited: 5 chip-namn → science-namn +
  filter_keyword claim_keywords→keywords. get_trending_keywords:
  claim_keywords→keywords. Frontend rad 2849: toDbRole(role). Verifierat
  live: konsol ren, MOST CITED laddar rikt (Bailey's 3056…), RESEARCH PULSE
  9 408 artiklar med rik keyword-lista.

### VIKTIG INSIKT — redesignen är OMFLYTTNING, inte nybygge
Skärmdumpar avslöjade att Feed REDAN har MOST CITED, TOP TOPICS, JOURNALS,
RESEARCH PULSE, trendmoduler, ASK THE RESEARCH. Översikt ska FLYTTA dessa
från Feed, inte bygga nya. Billigare och tryggare än redesign-specen antog.
Redesign-specen uppdaterad med detta.

### Kvarvarande otrackat att committa (dokumentation)
- gustema-order-navigation-fas2.md
- gustema-order-commit-rpc-adoption.md
- gustema-order-diagnos-embeddings-fasA.md (om ej committad)
- dagens tillägg + backlogg-filer

---

## Tillägg till §8 — Att göra

### Nya backlogg-punkter denna session
1. **Lint utökas att skanna migrations/** (gustema-order-lint-migrations-scan.md,
   committad b5e76ee). Nu när RPCerna bor i git kan linten se dem. Rekommendation:
   linta på git-diff mot main, inte hela trädet (historiska drop-migrationer).
   Låg brådska, hög värde — stänger lärdom-7/13-hålet mot FRAMTIDA återfall.
2. **Relevans-bortfall (gustema-backlogg-relevans-bortfall.md):** tappar vi
   artiklar för en profession pga andra benämningar? (waiter vs sommelier).
   Egen diagnos-session: är relevance-check semantisk eller nyckelord?
   Trovärdighet (K3.4). HÖG.
3. **F-O3 mest citerade INTERVALL (skärpning av redesign-spec):** specen vill
   månad/år/5 år. VERIFIERA FÖRST: har vi citeringar-ÖVER-TID per artikel,
   eller bara ett totalt citation_count? Browsern visade rika totaler
   (Bailey's 3056) men det är sannolikt EN total, inte tidsserie. Om bara
   total → "senaste månaden" kan INTE byggas som citeringar-i-fönstret; blir
   "publicerade i fönstret, sorterat på total". Bekräfta mot data + med Anders
   vad intervallet ska betyda innan bygge. (Citeringsdata FINNS — tidigare oro
   om tunn data var fel, den var bara filtrerad; nedgraderad.)

### get_most_cited null-roll gav bara 2 (SQL) men browser visar 5+ rika
Förklaring: null-roll utan citation-filter i SQL vs frontend som filtrerar
på roll. Datan finns rikligt (browser bevisade). Ingen åtgärd — mätartefakt,
INTE datalucka. (Struket som oro.)

---

## PROCESSNOT
Sessionen spretade (redesign-spec + navigation + RPC-audit + disk-full
mitt i). Men disciplinen höll: diagnos före fix, verifiering i tre lager
(SQL → lokal browser → produktion), audit av HELA populationen (8 RPCer,
inte bara 1), commit först efter grön produktion. Det röda 400-felet blev
en full lärdom-7/11/13-städning i stället för en punktfix.

Nästa session: EN tråd. Föreslaget: Översikt-bygget (flytta Feed-moduler
dit) ELLER relevans-bortfall-diagnosen (hög, trovärdighet). Inte båda.
