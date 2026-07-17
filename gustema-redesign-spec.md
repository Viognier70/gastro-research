# Gustema — redesign-spec
**Datum:** 2026-07-16
**Status:** Vision + struktur fastställd (Översikt + Feed). EJ byggd.
**Modus:** Bygg med fräscha ögon, en vy i taget, i egna byggsessioner.
**Läs med:** gustema-kontextexport-2026-07-15 (+ tillägg), backlogg, lanseringschecklista.

> Denna spec föddes ur en genomgång vy för vy (ordning/uttryck/placering/
> design). Den fångar BESLUT, inte konversation — källan till sanning så
> byggsessioner slipper återuppfinna allt via kontext-hint.

---

## PRODUKTVISION (den bärande idén)

> **RELEVANS-ARKITEKTUR — BESLUTAD 2026-07-17 (modell 2: innehåll som ryggrad).**
> Roll är INTE rätt primär axel — den är en lins. Beslutad modell:
> **Innehåll (artiklar) är ryggraden, alltid sökbart. Roll och keyword är
> kombinerbara linser man lägger på/tar av.** Score RANKAR prominens,
> GATE:ar inte existens. Inget blir permanent osynligt.
>
> Bekräftat av relevans-diagnosen (gustema-relevans-diagnos.md): 46% av
> artiklar nådde ingen rolls tröskel och blev osynliga — det är gate-buggen.
> Och Anders insikt: tväraxlade ämnen (produktutveckling, hållbarhet,
> fermentering, nutrition) är KEYWORD-LINSER, inte roller — de är relevanta
> tvärs över alla roller. LÄGG INTE till fler roller; lägg till linser.
>
> **Byggs i tre lager (beslutade, sekventiella):**
> 1. **Score → ranking, inte gate.** Sökning når ALLA artiklar oavsett
>    score. Löser 46%-osynligheten. Halvvägs byggt (keywords-kolumn återställd
>    2026-07-15). Minsta steg, störst effekt.
> 2. **Multi-roll.** Användaren väljer FLERA roller, flödet = union (OR över
>    relevance_sci_*-kolumner). Billigt (ingen ny data), löser gränsfallen
>    (vinservice når den som valt sommelier+hospitality), speglar verkligheten
>    (många är flera saker). Första steget in i modell 2.
> 3. **Full modell 2.** Innehåll som ryggrad, roll + keyword som kombinerbara
>    linser (F-O8 + PCA-karta). Roll = vem du är; keyword = vad du söker nu.
>    Störst bygge, dit redesignen redan lutar.
>
> Varning lager 2: väljer man alla fem roller får man allt → filtret
> meningslöst. Därför MÅSTE roll kombineras med keyword/ämne för att vara
> vasst. De två linserna hör ihop.

## PRODUKTVISION (ursprunglig)

> **UPPDATERING 2026-07-16 — REDESIGNEN ÄR OMFLYTTNING, INTE NYBYGGE.**
> Skärmdumpar under navigations-sessionen avslöjade att Feed REDAN har
> MOST CITED, TOP TOPICS, JOURNALS, RESEARCH PULSE, trendmoduler och ASK
> THE RESEARCH — byggda och fungerande. Översikt ska FLYTTA dessa moduler
> från Feed, inte bygga dem från noll. Billigare och tryggare. Undersök
> vad som finns FÖRE bygge; återuppfinn inte det som redan fungerar.

**Gustema är inte en söktjänst man besöker — det är en levande fält-bevakning
man FÖLJER.** Som börsappen eller nyhetsappen man öppnar på morgonen. Man
laddar ner den på telefonen för att hålla sig à jour med sitt gastronomiska
delfält: vad som är nytt, vilka keywords som dominerar, hur världsforskningen
ser ut, och vilka som samförfattar internationellt.

Fyra ledord (Anders): **nyhetstidning med ingress · live aktiebörs ·
vetenskaplighet · lättillgänglighet.**

**USP som huvudattraktion (inte gömd funktion):** att följa ett delfält som
ett levande system — nya artiklar, hetaste begrepp, geografin, samförfattar-
nätverken — i fickan. Sökning har alla; *bevakning av ett fält* har ingen så här.

---

## ARK1 — ARKITEKTUR: dela efter TIDSLIGHET (BESLUTAT)

Inte efter innehållstyp, utan efter om innehållet lever eller är statiskt.

| Vy | Roll | Innehåll |
|----|------|----------|
| **Översikt** (landning) | Det levande | Live-signal, huvudnyhet m. ingress, mest citerade (tidsfönster), dominerande keywords, granskningsstaplar, samförfattar-nätverk, syntes-utdrag |
| **Feed** | Arkivet | Sök, yrkespills, hela artikelflödet — rent, ostört |
| **Explore** | Semantisk navigering | PCA-kartan (egen spec, gatad) |
| **Map** | Geografin | Som nu (efter kart-buggfixar) |

- **Namn:** "Översikt" / "Overview" (tvåspråkigt rent; lovar helhet, inte
  bara "senaste"). Kontrastpar: Översikt = läget nu · Feed = allt.
- **Syntheses försvinner som toppflik** — absorberas i Översikt som
  redaktionell kärna, men behåller egen läsvy nås via länk. Tas bort ur
  navigationen, INTE ur produkten.
- **Översiktens moduler är klickbara ingångar till djupet** (dirigent, inte
  återvändsgränd): topic → Feed förfiltrerad; mest-citerad → artikeln;
  syntes → synteser-vyn; samarbeten → Map.
- Fyra flikar totalt (inte fem) — löser navigations-svällningen (K2.2).

---

## ÖVERSIKT — mobilt newsboard (mockup finns i sessionen)

**Mobil-först är HUVUDSCENARIOT, inte en anpassning** ("ha appen nedladdad på
telefonen för att följa vad som händer"). Horisontella dashboard-moduler
staplas och prioriteras för en tumme på ~380px.

### Fält-fokus
- Topp: **"Din bevakning: <fält>"** (t.ex. Novel foods). Hela Översikt kan
  fokuseras på ETT delfält (via roll eller valt ämne) → huvudnyhet, keywords,
  karta, samförfattare blir DET fältets bevakning. Default kan vara global
  eller rollens fält.

### Moduler (uppifrån)
1. **Header:** wordmark + LIVE-prick. Fält-väljare.
2. **Live-ticker:** rullar det som rör sig — "34 nya denna vecka · umami ▲ ·
   3 nya samarbeten". Börs-känslan. MÅSTE vara äkta (lärdom 6: rör sig bara
   för att data rör sig; falsk animering underminerar trovärdighet, K3.4).
   Drivs av lätta förberäknade signaler (gusto_health-matvyn, EJ råtabell —
   lärdom 9).
3. **Huvudnyhet med ingress:** punchig läsbar rubrik (Gustema-genererad) +
   **ingress i klartext** — episteme kokad ner till nyhetsboard-nivå, INTE
   episteme rakt av (för teknisk). "Läs mer →" rakt till DOI för den nyfikne.
   Vetenskaplighet kvar men diskret (journal · år · citerad N×).
4. **Dominerande keywords:** hetaste begrepp i fältet, storlek/vikt = frekvens.
   Bygger på `keywords`-kolumnen (den vi återställde 2026-07-15).
5. **Mest citerade:** tidsfönster månad/år/5 år (växlingsbart). KRÄVER
   citeringsdata per artikel — VERIFIERA mot DB innan låsning (OpenAlex har
   citeringar; kan vara backfill). Kopplar K2.3.
   **SKÄRPNING 2026-07-16:** citeringsdata FINNS (verifierat live: Bailey's
   3056, Ultra-Processing 2190…). MEN sannolikt bara ETT totalt
   citation_count per artikel, INTE en tidsserie. Innan intervallen byggs:
   verifiera om vi har citeringar-ÖVER-TID eller bara total. Om bara total →
   "senaste månaden" kan inte betyda "citeringar under månaden"; det blir
   "artiklar PUBLICERADE i fönstret, sorterat på total-citeringar". Bekräfta
   med Anders vad intervallet ska betyda innan bygge. get_most_cited-RPC:n
   (lagad + i git 2026-07-16, b5e76ee) tar redan limit + topic/keyword/roll
   men INTE tidsfönster — det ska läggas till här.
6. **Granskade i dag:** räknare med växande stapel (databasen andas).
7. **Internationella samarbeten:** samförfattar-nätverk mellan institutioner.
   USP-huvudelement. Bygger på collab-data (finns i Map) — VERIFIERA att
   datan är rik nog innan den blir Översikt-modul.
8. **Syntes-utdrag:** "uppdaterad i dag", länk till full synteser-vy.
9. **Botten-nav:** Översikt · Feed · Explore · Map (tummvänligt).

---

## FEED — arkivet (mockup finns i sessionen)

Befriad från allt aggregerat (det bor i Översikt nu). Bara ingång + flöde.

1. **Sök** — titel/författare/keyword, mot arkivet.
2. **Sortering** — senaste / mest citerade / relevans. ÖPPET: dropdown vid
   sökfältet? (beslut kvar)
3. **Yrkespills (F-O8) — rollmedvetna sökvägar:** översätter yrkesspråk →
   databas. Sommelier → produkter (vin/te/kaffe/öl/surdeg); Hospitality →
   servicescape/tourism service/revenue; Forskare → metoder (CATA/JAR/TDI).
   - **Byter med rollen** (roll-chippet finns redan) ELLER alla synliga
     grupperade — ÖPPET beslut.
   - **DATAVALIDERING KRÄVS:** finns "surdeg", "CATA", "revenue management"
     osv som keywords i DB, och hur många träffar? En pill som ger noll är
     värre än ingen pill (lärdom 11). Söker mot `keywords`-kolumnen.
4. **Rent artikelflöde** — bara kort, ingen aggregering emellan.

---

## KORTEN — bevaras (kort-UX byggdes om 2026-07-13, är bra)

**Kortens innehåll och 3-lagerlogik ska INTE byggas om.** Fullständigt kort
innehåller idag (verifierat mot produktion): eyebrow/topic · Gustema-rubrik ·
affiliation · ORIGINALTITEL (märkt) · författare · journal+år · core_claim
(gyllene box) · limitation-ruta (lager 2) · Cite · Share · Read paper (DOI ↗) ·
☆ Save · TRIAD-expander.

### Enda föreslagna kort-ändring: F-D1 — TRIAD som linser
- Idag: "Show TRIAD analysis ↓" (en expander → tre band ε/τ/φ).
- Förslag: gör ε/τ/φ till **klickbara flikar/linser** — klicka Techne → se
  hur kunskapen kan operationaliseras; Episteme → det analytiska; Phronesis →
  det situerade. TRIAD blir aktivt val, inte passiv presentation.
- **ÖPPET:** ersätter flikarna expandern helt, eller komplement (expander kvar
  för "visa allt", flikar för "visa en lins")?
- **Syskon till K2.9** (TRIAD som sökfilter) — samma mekanik på två nivåer,
  designa ihop.
- **Korsar K3.1** (TRIAD transparent vs hemlig/patenterbar) — hur djupt
  flikarna exponerar motorn kan behöva vänta på det strategibeslutet.

---

## ÖPPNA FRÅGOR (avgörs i byggsessioner / av Anders)

- Huvudnyhet: en utpekad "förstasida"-story vs. jämnstor dashboard? (tidnings-
  referens vs börs-referens — Anders lutar nyhetstidning m. ingress).
- Översikt default: global vs rollens fält?
- Återkommande användare: kan Feed sättas som startvy i stället för Översikt?
- Feed-sortering: var bor valen?
- Yrkespills: rollväxlande vs alla synliga?
- F-D1: flikar ersätter vs kompletterar expandern?

## DATABEROENDEN att verifiera FÖRE bygge (lärdom 10/11)
- Citeringsdata per artikel (mest citerade + tidsfönster) — finns? backfill?
- Collab/samförfattar-data — rik nog för Översikt-modul?
- Yrkespill-termer mot `keywords` — vilka ger meningsfulla träffar?
- Live-ticker-signaler mot gusto_health-matvyn (ej råtabell).

## BEROENDE PÅ REDAN PÅGÅENDE
- **Färg-shared-const** (Claude Code bygger nu): alla topic/keyword-färger i
  mockuparna är platshållare tills den är klar. En källa, konsumerad överallt.
- **Keyword-fixen** (klar 2026-07-15): yrkespills + dominerande keywords
  bygger på den återställda `keywords`-kolumnen.

## FÖRESLAGEN BYGGORDNING (en vy per session)
1. Navigation/informationshierarki (K2.2) — sätt de fyra flikarna + Syntheses-
   som-länk. Grunden allt annat hänger på.
2. Översikt-framsidan (mobil-först) — störst värde, störst bygge.
3. Feed-förenkling (lyft ut aggregerat → Översikt; lägg yrkespills).
4. F-D1 TRIAD-linser (efter K3.1-beslut).
Resterande vyer (Explore=PCA gatad, Map efter buggfix) enligt egna specar.
