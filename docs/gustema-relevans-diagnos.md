> _Arkiv — skriven under namnet Gustema, nu Gusto Science._

# Gustema — relevans-diagnos: bortfall + arkitekturprincip
**Datum:** 2026-07-17
**Ursprung:** Anders fråga — tappar vi artiklar för en profession pga andra
benämningar? (waiter vs sommelier). Svar: JA, på TVÅ ställen, men inte där
hypotesen först pekade.
**Status:** Diagnos komplett. Åtgärder pågår/scopas.

---

## BÄRANDE PRINCIP (Anders insikt — viktigast i hela dokumentet)

**Relevansscore = ranking/prominens, INTE en existens-gate.**
En artikel ska FINNAS i databasen och vara sökbar/keyword-filtrerbar även om
relevance_sci_{roll} score:ades 4 istället för 5. Scoren avgör vad som visas
PROMINENT för en roll — inte vad som existerar eller går att hitta.

Konsekvens: åtkomst garanteras av **sökning + keyword-filter (F-O8) +
roll-kombination**, inte av att Haiku score:ar "rätt". En sommelier som söker
"sensory evaluation" ska hitta en fMRI-vinstudie oavsett dess sensory_pro-score.

Detta gör att de två läckorna får HELT olika vikt (se nedan).

---

## DIAGNOS — vad som faktiskt händer

### Klassnings-mekanismen (grunden är sund)
- Relevance-check är SEMANTISK (Haiku läser abstract, sätter 5 oberoende
  scores per roll). INTE nyckelordsmatchning.
- Tvingar INTE artiklar till en roll. Q7: artiklar får generöst FLERA roller
  (43% har 4-5 roller, bara 1% har exakt 1). Roll-tvång-hypotesen motbevisad.

### LÄCKA 1 — Inhämtnings-allowlist (DEN VERKLIGA PRIORITETEN)
- daily-fetch har FOOD_KEYWORDS-allowlist. Artikel vars TITEL saknar kulinärt
  ord kastas INNAN databasen (om ej trusted journal).
- Allowlisten saknar service/hospitality-vokabulär → "Server-guest interaction
  in fine dining", "Tipping and service quality" hämtas ALDRIG.
- Bevis: Q10 fann bara 21 service-artiklar TOTALT i hela DB. Fingeravtrycket
  av strukturellt bortfall vid inhämtning.
- **Varför värst:** det ohämtade kan aldrig sökas, keyword-filtreras eller
  nås — oavsett hur bra sökningen är. Permanent otillgängligt. Lärdom 7 i
  renaste form: du vet inte vad du inte har.
- Slår mot hela hospitality_mgmt-rollen (en av fem).

### LÄCKA 2 — Prompt under-scoring (NEDGRADERAD tack vare principen)
- Prompt: "BE STRICT: only high if professional can directly apply in daily
  work". Straffar artiklar om en rolls KÄRNKOMPETENS (sommelier gör redan
  vinservice → "ingen ny daglig tillämpning" → score <5).
- Bevis: Q8c-stickprov, 8-10 av 30 gråzon-titlar hade "sensory"/"sommelier"
  I TITELN men score <5. Inkl. "sommelier fMRI sensory integration".
- Abstract kapas vid 400 tecken (halva vad TRIAD ser). Roll-etiketter saknar
  domänförklaring i prompten.
- **Men NEDGRADERAD:** artiklarna FINNS i databasen. Med sökning + keyword +
  roll-kombination (F-O8) är de åtkomliga. Scoren påverkar bara feed-prominens.
  Fix = bra sökning/keyword-filter, INTE prompt-kirurgi.
- Anders bedömning: Q8-artiklarna är "i olika grad relevanta för sommelier" —
  dvs de ska vara ÅTKOMLIGA, inte nödvändigtvis top-rankade.

---

## ÅTGÄRDER (prioritetsordnade, scopas — INTE gjorda)

### BESLUTAT 2026-07-17: modell 2 (innehåll som ryggrad), tre lager
Roll är fel primär axel — den är en lins. Innehåll är ryggraden. Score rankar,
gate:ar inte. Tväraxlade ämnen (produktutveckling, hållbarhet, nutrition) =
keyword-linser, INTE roller. Lägg INTE till fler roller. Se redesign-spec §0.

**Lager 1 — score → ranking, inte gate (minsta steg, störst effekt)**
Sökning + keyword-filter når ALLA artiklar oavsett relevance_sci-score.
Löser 46%-osynligheten (13 625 artiklar som nådde ingen roll). Halvvägs
byggt (keywords-kolumn återställd). Verifiera: når feed-sök hela articles,
eller filtrerar den redan på score >= 5? Om det senare → ta bort den gaten.

**Lager 2 — multi-roll (union av valda roller)**
Låt användaren välja FLERA roller; flödet = OR över relevance_sci_*-kolumnerna
i stället för att välja EN kolumn. Billigt (ingen om-scoring), löser
gränsfallen (vinservice når sommelier+hospitality), speglar verkligheten.
Kombinera med keyword så flödet inte blir spretigt vid många roller.

**Lager 3 — full modell 2 (F-O8 keyword-linser + PCA-karta)**
Innehåll som ryggrad, roll + keyword som kombinerbara linser. Roll = vem du
är; keyword = vad du söker nu. Störst bygge, dit redesignen redan lutar.

### Kvarstår oberoende: bredda INHÄMTNINGEN (läcka 1)
Modell 2 löser PROMINENS (score-gate), men inte INHÄMTNING. Det som aldrig
hämtas kan aldrig sökas ens i modell 2. FOOD_KEYWORDS-allowlisten kastar
service/hospitality-forskning INNAN DB (Q10: bara 21 service-artiklar totalt).
Princip: hämta BRETT, filtrera vid visning, inte vid inhämtning.
- Framåt: bredda FOOD_KEYWORDS med hospitality/service-vokabulär. Enkel, men
  → fler artiklar → mer pipeline-kostnad. Väg kostnad mot täckning.
- Retroaktivt missade artiklar = borta ur historiken. Riktad backfill = eget projekt.

### Prompt-kalibrering (läcka 2) — NEDGRADERAD av modell 2
"BE STRICT: daily application" straffar kärnkompetens-forskning (Q8c:
sommelier-fMRI score <5). MEN i modell 2 är artiklarna åtkomliga via
keyword/sök oavsett score → ingen prompt-kirurgi brådskande. Ev. senare
finjustering om budget/tid.

---

## PRODUKTBESLUT SOM KRÄVS (Anders)
Är hospitality_mgmt en roll ni lanserar med full täckning, eller medvetet
nedprioriterad i v1? Legitimt att lansera med 3-4 starka roller hellre än 5
halvbra — MEN copyn måste då matcha (inte lova hospitality-täckning ni saknar,
K3.4). Om full täckning krävs → åtgärd B före lansering.

---

## KOPPLING TILL LANSERING
Trovärdighetskritiskt (K3.4): produkten säljer "för [roll]" men får inte
systematiskt sakna deras kärnämne. Åtgärd A (keyword-filter) löser mest av
prominens-frågan och är redan planerad. Åtgärd B (inhämtning) är det som
avgör om hospitality-rollen har substans. C är finjustering.

Ordning: A (redesign, bygg ändå) → B (produktbeslut + bredda) → C (om budget/tid).
