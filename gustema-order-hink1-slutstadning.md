# ORDER — Hink 1 slutstädning (palett, legend, title, counts)
**Datum:** 2026-07-15
**Kontext:** K1.2 löst (12/7, verifierad), K1.1a+b löst (fd69e55, live-räknare).
Detta är resten av Hink 1 + bifynd från skärmgranskning av Research landscape.
**Allt i index.html — en resa, en commit-familj. Ingen DDL.**

---

## FAS A — RAPPORTERA FÖRST (inga ändringar än)

### A1. Dumpa hela ämne→färg-mappningen (K1.5)
- Hitta var färger per ämne definieras i index.html (objekt/array/CSS).
- Rapportera FULLSTÄNDIG lista: ämne → hexfärg.
- Rapportera VAR mappningen konsumeras: Feed-chips, karta, research
  landscape, pills. Finns det EN källa eller flera parallella mappningar?
  (Om flera: det är rotorsaken — två saker får inte heta samma sak.)
- Kända kollisioner från skärmdump 2026-07-15:
  - Grön ×4: Hospitality, Fermentation science, Food technology, Food science
  - Blå ×3: Multisensory, Nutrition science, Sensory evaluation
  - Lila ×3: Food behavior, Food psychology, Atmospherics
  - Rost ×3: Novel foods, Appetite research, Food anthropology

### A2. Hitta "show articles"-frågan (K1.1c — kvarstående delbugg)
- Kartans "show articles"-länk: vilken fråga/filter kör den?
- Varför visar den inte ALLA artiklar? Rapportera predikatet + hypotes.
- Jämför antal länken visar vs oberoende count(*) med samma avsedda villkor.

### A3. Layout-blink (K1.4) — diagnos
- Riktig browser, DevTools Performance → Layout Shift.
- Rapportera CLS-källa: bild utan width/height? font-swap? sen feed-render?
- Ingen fix än — bara identifiera elementet.

---

## FAS B — FIXA (efter godkänd A-rapport)

### B1. Unik färg per ämne (K1.5)
- EN kanonisk mappning ämne→färg, definierad på ETT ställe, konsumerad överallt.
- ~16 ämnen = ~16 distinkta nyanser. Håll Gustemas palett-känsla (dämpade,
  jordnära toner), men ingen färg får återanvändas mellan ämnen.
- Verifiera i browsern: Feed-chips, karta, landskap, pills — samma färg för
  samma ämne överallt, ingen kollision någonstans.

### B2. Ta bort dubbellegenden i Research landscape
- Två legender säger samma sak med olika ord:
  övre: "Active topic / Research area / Connected fields"
  nedre: "Core topic for your role / Related area / Shared focus"
- BEHÅLL den nedre (rollmedveten, mer precis). Ta bort den övre.
- Verifiera att inget annat refererar de borttagna elementen (grep).

### B3. Count-inkonsekvens i landskapet
- Endast Gastronomy-noden visar antal (845). Beslut: visa count på ALLA
  noder (diskret, under etiketten) — node size finns redan men siffran
  ger precision. Om det blir plottrigt vid små noder: visa vid hover.

### B4. Etikett-städning i landskapet
- "uncategorized" → "Uncategorized" (versalisering som övriga).
- Fermentation science-etiketten krockar med Aristoteles-citatet —
  justera citatets position eller nodens etikettplacering.

### B5. Title-tagg (branding-kvarleva)
- <title> lyder "Gusto Science - Gustema — research intelligence for
  gastronomy". Ändra till "Gustema — research intelligence for gastronomy".
- Grep efter fler "Gusto Science"-förekomster i index.html (meta og:title,
  og:site_name, description, manifest). Rapportera + rätta alla.
  OBS: rör INTE domännamn/URL:er (gusto.science är fortfarande live-domän).

### B6. Favicon-verifiering (K1.3 — endast ögon)
- Efter deploy: riktig browser, ljust + mörkt tema. Syns faviconen mot båda?
- Om ja: bocka av K1.3, rör inget. Om nej: rapportera, fixa INTE i denna order.

---

## VERIFIERING (produktionsvägen, lärdom 3)
Efter CF-build, i riktig browser:
1. Landskapet: unika färger, en legend, counts konsekventa, etiketter rena.
2. Feed: chips har samma färger som landskapet för samma ämne.
3. Fliktitel visar "Gustema — …".
4. Favicon båda teman.
5. Ingen console-error (särskilt inget svalt i catch — logga vid tvivel).
