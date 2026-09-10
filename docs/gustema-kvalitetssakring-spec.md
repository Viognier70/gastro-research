> _Arkiv — skriven under namnet Gustema, nu Gusto Science._

# Gustema — Kvalitetssäkring av TRIAD & praktikerkunskap
**Skapad 2026-07-23 · Status: DEL A pågår (FÖRE-mätning klar, batch-regen kör, EFTER-mätning väntar)**

## Varför detta dokument

Gustema säljer *vetenskaplig trovärdighet* — "peer-reviewed forskning översatt".
Men kedjan har två obeprövade led:

| Led | Verifierat? |
|-----|-------------|
| Artikeln (peer-reviewed) | ✅ av vetenskapen |
| **TRIAD-analysen av artikeln** | ❌ ~9 700 st, AI-genererade, **noll mänsklig granskning** |
| Urval i Ask (pgvector + hybrid-gate) | ⚠️ 4 testfall (2026-07-23) |
| Ask-syntesen över urvalet | ⚠️ 4 testfall (2026-07-23) |

En felaktig TRIAD som når en kock (fel temperatur) eller en lärare (fel slutsats
i undervisning) skadar inte bara en kund — den underminerar produktens premiss.
Vi vet i dag inte om felfrekvensen är 2 % eller 20 %.

Detta dokument beskriver tre sammanhängande insatser, i byggordning.

---

## DEL A — TRIAD-kvalitetsmätning (FÖRE lansering)

**Mål:** en faktisk felfrekvens att förhålla sig till och förbättra mot.

### STATUS 2026-07-23 (uppdatering)

**FÖRE-mätningen är GJORD** — 25 stickprovsartiklar, granskade av Anders mot originalartiklarna. Utfall:
- **Rotorsak identifierad:** TRIAD-genereringen matades med max 300 tecken parafras (`insight`, en Haiku-sammanfattning av abstract) och prompten krävde "60–80 ord instruktionell 2:a person" per techne-fält. Otillräckligt underlag + krav på konkretion → **konsekvent fabricering av specifika värden** (pH, temperaturer, ingrediensnamn, platsnamn) attribuerade till artiklar som inte innehöll dem. Trogen på övergripande innehåll, fabricerade specifika detaljer.
- **Kända fabriceringar (7 av 25):** pH 6.8 (nr 2 fisksås), 150°C i 5 min (nr 3 hot pot), piyaz/tantuni (nr 5), EUC-beräkning (nr 7), Japan-kaiten-zushi + -40° (nr 15), furaner/pyraziner (nr 21). Nr 4 (hexanal/nonanal) verifierades korrekt — förekom faktiskt i artikelns tabell.
- **Bredare påståenden var korrekta.** Nr 8, 11, 13, 17 alla passerade. Rollmatchningen (nr 9, 10) OK.
- **Fyndbrytpunkt:** felen var *strukturellt frampressade av arkitekturen* — inte en modell-vagabond som slumpvis hallucinerar. Rotorsakslösning möjlig.

**ÅTGÄRD implementerad:** prompt-fix (`_shared/labeled-triad.ts` v4, deployad 2026-07-23 till `pipeline`, `triad-on-demand`, `triad-background`).
- Källordning bytt: `abstract || insight` (originalet först, insight bara som fallback för artiklar som väntar på abstract-backfill)
- Cap höjd: 300 → 2000 tecken (nästan hela abstract)
- 5 STRICT RULES tillagda överst: förbud mot fabricering av numeriska värden, ingrediensnamn, platsnamn, protokoll; explicit tillstånd för ärlig generalitet där abstract saknar specifikationer
- Techne-instruktionen omformulerad: "40–80 words 2nd person" utan "instructional", + "state only values/protocols that appear in the abstract"
- MIN_LEN sänkt 180 → 120 tecken (validateTriad accepterar kortare-men-sanna svar)

**Bevisad på 3 av 6 stickprovs-fabriceringar** (nr 2, 3, 21) via triad-on-demand-regenerering. Alla fabricerade siffror borta, ersatta med "as reported" eller ärlig generalitet.

**Batch-regenerering (v4-prompt på hela korpusen) i pipeline:**
- Script: `scripts/batch-regen-triad.ts` (Anthropic Batches API, ~50% rabatt, klart inom 24h)
- Uteslutning: `irrelevant = true` — **populationsräkning 2026-07-23 avslöjar 45% läckage** (av ~9 700 befintliga TRIAD sitter ~4 400 på irrelevant-flaggade artiklar, osynliga för användaren men konsumerade Sonnet-budget). Stickprovet visade 28% men verkligheten är värre.
- Uppskattad kostnad: **~$425** för **33 305 aktiva artiklar** (5 285 befintliga TRIAD + 28 020 i kö, alla `irrelevant is not true`)
- **Täckningsvinst:** analyserat bibliotek 5 285 → 33 305 (6,3×)
- ETA: några timmar upp till 24h beroende på Anthropic-batch-schedule
- **Se även L6.5:** kön växer (48/dag throughput << ingesting-takt) — batchen köper tid men löser inte throughput-gapet

**EFTER-mätning väntar:** se `gustema-triad-eftermatning.md` för spec. Nytt slumpurval om 25, samma protokoll, trösklar satta INNAN mätning:
- core_claim + Episteme ≥ 90% Korrekt
- Techne ≥ 75% Korrekt/Delvis + **noll fabricerade numeriska värden** (absolut krav)
- Phronesis ≥ 70% Korrekt/Delvis

**Slutgiltig kvalitetsbedömning kvarstår tills EFTER-mätningen är klar.** Utan den vet vi inte om fixen håller på hela korpusen — bara att den håller på 3 stickprov.

---


### A.1 Urval (representativt, ~25 analyser)
Slumpa, men stratifiera så alla ytor täcks:
- **5 per yrkesroll** (sensory_pro, culinary_pro, gastronomy_culture,
  hospitality_mgmt, educator_researcher) = 25 st
- Inom varje roll: sprid över **relevans** (hög 8-10, mellan 5-7) och över
  **studietyp** (experimentell, review, observational) — feltyper kan skilja
- Sprid över **publiceringsår** (nytt vs äldre) och **journal-typ**
- SQL bör dra slumpmässigt inom varje stratum, inte de första bästa

### A.2 Vad som bedöms per analys
Granskaren (Anders, forskare i fältet) läser TRIAD:en **mot originalartikeln**
och bedömer fyra saker:

| Fält | Fråga | Betyg |
|------|-------|-------|
| **Episteme** | Håller den sig till vad artikeln faktiskt fastställer? Övertolkning? Utelämnade förbehåll? | Korrekt / Delvis / Fel |
| **Techne** | Är tillämpningen härledd ur artikeln, eller uppdiktad? Praktiskt användbar? | Korrekt / Delvis / Fel |
| **Phronesis** | Situerat omdöme grundat i artikeln, eller generisk fyllnad? | Korrekt / Delvis / Fel |
| **core_claim** | Sammanfattar den artikelns huvudfynd rättvisande? | Korrekt / Delvis / Fel |

Plus fritextnotering om **feltyp** när något är Delvis/Fel:
- *Övertolkning* (säger mer än artikeln stödjer)
- *Fabricering* (specifika värden/protokoll som ej finns i artikeln)
- *Missförstånd* (har läst artikeln fel)
- *Generisk fyllnad* (säger inget artikelspecifikt)
- *Rollmissmatch* (analysen passar inte den yrkesroll den är gjord för)

### A.3 Resultat
- **Felfrekvens per fält** (t.ex. "episteme 92 % korrekt, phronesis 71 %")
- **Vanligaste feltyp** — styr vad som ska förbättras (prompt? modell? urval?)
- **Beslutspunkt:** vad är acceptabelt för lansering? Förslag: ≥90 % korrekt på
  episteme + core_claim (de faktapåstående lagren) är minimikrav; techne/phronesis
  får vara svagare eftersom de är tolkande — men det ska då *sägas* i copy.

### A.4 Om felfrekvensen är för hög
Åtgärder i ordning: (1) skärp TRIAD-prompten mot de vanligaste feltyperna,
(2) höj relevanströskeln för vilka artiklar som analyseras, (3) byt modell för
generering, (4) begränsa lanseringen till de roller/ämnen där kvaliteten håller.

---

## DEL B — Community-verifiering (EFTER lansering, Pro)

**Mål:** skala granskningen bortom vad en person orkar, och göra kvaliteten till
en gemensam angelägenhet.

### B.1 Vad Pro-medlemmar kan göra
- **Flagga** en TRIAD-analys som felaktig, med feltyp (samma taxonomi som A.2)
  och fritext-motivering
- **Bekräfta** att en analys stämmer (positiv signal, inte bara felrapporter)
- **Kommentera** med erfarenhet/tillämpning (se Del C)

### B.2 Hur flaggor hanteras
- Flaggad analys får en **synlig markering** för alla användare
  ("⚑ En medlem har ifrågasatt denna analys")
- Vid **N flaggor** (förslag: 2+ oberoende) → analysen döljs/markeras starkare
  tills granskad
- Anders (eller framtida redaktion) granskar och antingen **rättar** (regenererar
  TRIAD) eller **avfärdar** flaggan
- Flaggstatistik blir kvalitetsdata: vilka roller/ämnen genererar flest fel

### B.3 Varför det stärker Pro
Det blir en **tredje Pro-motivator** vid sidan av Ask (praktikern) och kartorna
(forskaren): att *bidra* till fältets kunskapskvalitet. Forskare är redan tränade
i peer review och värdesätter det.

---

## DEL C — Praktikerkunskap som fjärde lager

**Mål:** låta produkten leva sin egen kunskapsteori.

### C.1 Grundtanken
TRIAD säger att professionell kunskap kräver tre former. I dag genereras alla tre
av AI från artiklar — vilket gör **phronesis** (situerat omdöme) till en
*simulering* av erfarenhet. En kock som skriver "jag har testat detta; det
fungerar bara om luftfuktigheten är under X" bidrar med **äkta phronesis**.

Praktikerbidrag är alltså inte en kommentarsfunktion — det är den kunskapsform
produkten säger sig värdera men i dag saknar.

### C.2 Märkning (kritisk)
Praktikerkunskap **måste** visas som distinkt från forskningsgrundad kunskap:

```
ε Episteme (forskning) · τ Techne (tillämpning) · φ Phronesis (omdöme)
— separat block —
⌂ FRÅN PRAKTIKEN — bidrag från Pro-medlemmar. Erfarenhetsbaserat,
  ej vetenskapligt verifierat.
```

Utan tydlig gräns suddas skillnaden mellan peer-reviewed och anekdot — och då
faller hela trovärdighetslöftet.

### C.3 Datamodell (utgångspunkt: artikel-kopplat)
Praktikerbidrag knyts i v1 till **artikel + roll**:
- Naturligt för verifiering ("denna TRIAD missar X")
- Spårbart till konkret forskning
- Enkelt att bygga (bidrag → article_id, role, user_id, text, typ)

*Möjlig utbyggnad:* ämnes-/frågekopplade bidrag ("så här gör jag när jag torkar
örter") ligger närmare hur praktiker tänker och vore mer användbart i Ask. Byggs
när behovet visat sig i v1.

### C.4 Inmatning i Ask/TRIAD-generering — SISTA steget
När bidrag matas in i syntesen tillkommer en **tredje obeprövad yta**, nu med
mänsklig input som kan vara fel, motstridig eller skadlig. Krav innan detta:
- **Moderering**: vem får bidra, vad granskas, hur tas skadligt bort
- **Motstridighetshantering**: två praktiker säger motsatt sak — visa båda? vikta?
- **Säkerhetsspärr**: livsmedelssäkerhet (temperaturer, förvaring) får inte
  drivas av overifierade bidrag
- **Separat märkning i svaret** (C.2) — aldrig sammanblandat med forskningsgrund

---

## BYGGORDNING (viktigast först)

| # | Vad | När | Varför denna ordning |
|---|-----|-----|----------------------|
| 1 | **DEL A** — stickprov, felfrekvens | **före lansering** | Grunden måste vara känd innan något byggs ovanpå |
| 2 | **DEL B** — flagga/bekräfta (visning) | efter lansering | Skalar granskning; kräver användare som inte finns vid launch |
| 3 | **DEL C.1-C.3** — praktikerbidrag, visning only | efter B fungerar | Testa formen innan den påverkar generering |
| 4 | **DEL C.4** — bidrag in i generering | sist | Störst risk; kräver moderering + testad grund |

**Anders testar själv som Pro-medlem** mellan steg 2 och 3 — kommenterar,
flaggar, ser hur det fungerar och vilka feltyper som dyker upp i praktiken.

---

## ÖPPNA FRÅGOR
1. Acceptabel felfrekvens för lansering — var går gränsen? (A.3)
2. Artikel- vs ämneskopplade bidrag — bekräfta v1-valet (C.3)
3. Moderering: Anders ensam, eller betrodda medlemmar med förhöjd behörighet?
4. Ska bekräftade praktikerbidrag kunna *höja* en analys status
   ("verifierad av 3 praktiker"), eller bara komplettera?
