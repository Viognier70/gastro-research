# Gustema — prismodell & positionering

**Datum:** 2026-07-19
**Syfte:** Samla dagens produktförståelse + prisresonemang till ett beslutsunderlag inför lansering.
**Status:** Kärnbesluten fattade (nedan). Finjusteringar märkta ÖPPET / A-B-test.
**Relaterat:** `gustema-lanseringschecklista.md` (blockerare/nice-to-have — denna spec är INTÄKTSMODELLEN som checklistan förutsätter).

---

## PRODUKTEN — fyra linser + ett frågedrivet flöde, en kunskapsbas

Gustema är inte "en artikeldatabas med analys". Det är **fyra linser in i samma
kunskapsbas**, alla roll-översatta, plus ett **frågedrivet flöde** (Ask the
research). Alla vägar leder till samma artiklar; TRIAD översätter dem till handling.

| Lins | Frågan den svarar på | Talar starkast till |
|------|----------------------|---------------------|
| **Feed** | "Vad är relevant och nytt i mitt fält?" | Alla roller |
| **Research Landscape** (Explore) | "Hur hänger idéerna ihop, var rör sig fältet?" | Fördjupare, forskare |
| **Global Map** | "Vem gör detta, var, med vem?" | Forskare, lärare |
| **TRIAD** | "Vad betyder ett fynd konkret för mig?" | Praktiker |
| **Ask the research** (frågedrivet) | "Jag har en arbetsfråga — ge mig svar" | Praktiker (kärnvärde) |

Skala (2026-07-19): 459 978 artiklar indexerade, ~9 520 TRIAD-analyser, 26
forskningsområden, 5 roller. Screening-tratt: 459 978 → 32 086 relevanta (7%) →
9 515 TRIAD (2.1%). "1 in 48 survive" — gallringen SÄLJS som kvalitetssignal.

Positionering (redan i produkten): *"Science that tells you what, how, and when."*
TRIAD = Episteme (vad forskningen fastställer) · Techne (hur det tillämpas) ·
Phronesis (det situerade omdömet). Riktad mot HANDLING, inte råmaterial.

---

## PRISMODELLEN (beslutad 2026-07-19)

**Grundprincip:** Free ser ATT kunskapen finns och får VAD forskningen säger.
Pro får VAD DET BETYDER för dig och verktygen att arbeta med det.

| Lins / funktion | Free | Pro |
|-----------------|------|-----|
| Feed — artiklar, core_claim, limitation, IMRAD, länk | ✅ | ✅ |
| Ask the research — ställ fråga, se urval + core_claims | ✅ | ✅ |
| — TRIAD-svaren på det frågedrivna urvalet | 🔒 | ✅ |
| TRIAD-uppslag | 🔒 **3/mån** (smaka) | ✅ hela lagret + generera |
| Research Landscape — se karta, klicka noder, "new this week" | ✅ | ✅ + bevaka kluster |
| Global Map — All research | ✅ | ✅ |
| Global Map — **My topics + Collaborations** | 🔒 | ✅ |
| Arbetsflöde — nyhetsbrev, spara, sortera, konto | ❌ | ✅ |
| **Pris** | 0 | **€12/mån · €99/år** |

### De tre betalvärdena (ingen urholkas av cachen)

1. **Praktikerns fråge-TRIAD** — "ställ din arbetsfråga → forskningsgrundade,
   roll-översatta svar". Unika frågor → alltid ny generering möjlig → urholkas ej.
2. **Forskarens kartor** — Global Map (Collaborations) + Research Landscape.
   Levande, förbättras med data → urholkas ej.
3. **Allas arbetsflöde** — bevakning, spara, sortera, konto. Klibbigt, växer med
   engagemang → urholkas ej.

### De tre gates — och varför de sitter där

1. **TRIAD: 3/mån gratis.** Smaka på översättningen-till-handling, inte nog att
   stanna gratis. (Forskning: gate efter aha, aldrig före.)
2. **Ask the research: sök gratis, TRIAD-svar Pro.** Free hittar rätt artiklar
   (aha: "det finns forskning om precis min fråga"); Pro får svaret översatt.
3. **Collaborations + My topics: helt Pro.** Forskarens tydligaste betalvärde,
   finns ej gratis någon annanstans. (Beslutat: ingen gratis-smak av Collaborations.)

---

## ⚠️ KRITISK KOD-JUSTERING — Free-X måste räkna VISNINGAR, inte genereringar

**Nuläge (verifierat i triad-on-demand/index.ts 2026-07-19):** kvot dras BARA
vid ny generering. Cache-hit (artikel redan analyserad) returnerar rad 145-164
FÖRE kvot-claim → gratis. Så "3/mån" betyder idag "3 nya genereringar +
obegränsade cache-läsningar".

**Problem:** en Free-user som utforskar populära (cachade) ämnen ser obegränsat
många TRIAD utan att röra sina 3 → konverterar aldrig. Ju mer cachen växer,
desto svagare gate.

**Krav för prismodellen:** Free-X måste räkna TRIAD-**visningar** (cache ELLER ny),
så gate:n biter. Pro obegränsat. Detta är en KOD-ÄNDRING mot dagens beteende —
egen uppgift, verifieras mot Free-flödet.

*(Notera samspel med budget-cap 500/dag från 2026-07-19: den skyddar
Sonnet-kostnaden; Free-X-visningsgränsen är en separat produktgate.)*

---

## GO-TO-MARKET — två spår

| Spår | Publik | Krok | Väg |
|------|--------|------|-----|
| **1 (först)** | Yrkesroller; **forskare/lärare leder** | Global Map + Landscape + fråge-TRIAD | Direkt, akademiska + yrkesnätverk |
| **2 (sedan)** | Praktiker i community-grupper (kockar) | Fråge-TRIAD (svar på arbetsfrågor) | Viral delning (t.ex. FB-grupper) |

Forskare/lärare först: de utnyttjar ALLA linser + blir trovärdighetsankare
("används av forskare vid [lärosäte]"). Praktiker via community-grupper: viral
spridning, en delad TRIAD-skärmdump är gratis marknadsföring (skalar ej till
arbetsflöde → måste bli Pro för mer).

**Institution/site-license:** senare möjlighet, inte första spår. En engagerad
lärare som använder det i undervisning drar in lärosätet (B2B2C). Studenten
betalar aldrig individuellt (priskänslig + IMRAD-litterat → låg individuell
konvertering); institutionen betalar för alla. Pipeline-värde: studenter blir
praktiker.

---

## LAUNCH-FÖRUTSÄTTNINGAR (ej optional)

1. **Seeda cachen** — generera TRIAD för topp ~500-1000 artiklar/roll så
   gratis-smaken (3 uppslag) träffar substans, ej tomma väggar. Kontrollerat av
   dig, inom budget-cappen. Utan detta: Free-user klickar → o-cachat → lås →
   ingen aha → ingen konvertering.
2. **Map-backfill** — 89 av 1809 artiklar har institutionskoordinater nu.
   Forskare (första målgruppen) är mest krävande på just den datan → fyll mer
   innan de möter kartan.
3. **Instrumentera "låst TRIAD klickad"** — den mätpunkt forskningen pekar ut
   som konverteringsmotorn. Bygg från dag ett; visa uppgraderings-prompt I
   KONTEXT vid den låsta väggen efter förbrukad X (ej prissida, ej mejldrip).

---

## ÖPPNA BESLUT (dina att avgöra / A-B-testa efter lansering)

- **X = 3/mån** beslutat, men värt A-B-test (aha kan komma efter 1 eller kräva 5).
- **Pris €12/mån** beslutat; årspris €99 föreslaget (~31% rabatt, driver
  årsabonnemang enligt ChartMogul-data). Bekräfta årspriset.
- **Landscape-bevakning gratis eller Pro?** Skissat som Pro-tillägg; ÖPPET.
- **Ask-the-research: får Free se HELA urvalet eller topp-N?** Skissat: hela
  urvalet + core_claims. ÖPPET om det ska begränsas.
- **Positionering praktiker vs forskare i copy** — produkten talar till båda;
  copyn måste välja huvudbudskap per kanal (forskare-först nu).

---

## FORSKNINGSSTÖD (freemium/pricing-litteratur, 2026)

- **Gate efter värde, aldrig före aha** — X-provapå gör precis detta.
- **Sälj arbetsflöde, inte sandlåda** — bevakning/konto/kartor = klibbig
  konvertering; funktions-gating ensamt är svagare.
- **Akta överdrivet generös gratis-nivå** — freemium konverterar lågt (~2.6%);
  Gustemas räddning är att TRIAD:s handlingsbarhet låses (Free får råmaterialet,
  ej översättningen).
- **Praktiker konverterar bättre än akademiker på handlingsbarhet** → positionera
  mot praktiker (what/how/when), ej mot forskare nöjda med IMRAD.
- **B2B/team-gating där pengarna ofta finns** → institution som senare spår.

---

## SAMMANFATTNING

Produkten är MOGNARE än prismodellen — fyra linser + frågedrivet flöde byggda,
TRIAD-ramverk + positionering på plats, screening-förtroende, roll-översättning.
Det som återstår är INTE att bygga om något, utan att (a) sätta Free-X till att
räkna visningar (kod), (b) seeda cachen + fylla kartan (launch-förutsättningar),
(c) instrumentera konverteringsmätpunkten, och (d) gå till marknad forskare-först.

Kärnbesluten (3/mån · €12 · Collaborations helt Pro) fattade 2026-07-19.
