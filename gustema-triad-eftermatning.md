> _Arkiv — skriven under namnet Gustema, nu Gusto Science._

# Gustema — TRIAD-eftermätning (Del A slutgiltig)

**Skapad:** 2026-07-23
**Status:** SPEC (mätning väntar på att batch-regenereringen ska bli klar)
**Föregångare:** `gustema-kvalitetssakring-spec.md` Del A (FÖRE-mätning, 25 stickprov)
**Trigger för denna spec:** batch-regenerering av hela TRIAD-korpusen (~26k artiklar via Anthropic Batches API, script `scripts/batch-regen-triad.ts`)

---

## Bakgrund

FÖRE-mätningen (2026-07-23) på 25 slumpade stickprovsartiklar avslöjade **konsekvent fabricering av specifika värden** — pH, temperaturer, ingrediensnamn, platsnamn — attribuerade till artiklar som inte innehöll dessa uppgifter. Rotorsaken var strukturell: TRIAD-genereringen matades med max 300 tecken (`insight`-parafras av abstract) och prompten krävde "60–80 ord instruktionell 2:a person" per techne-fält. Det gav modellen otillräckligt underlag OCH ett krav på konkretion — resultatet blev påhitt med citation-signal.

Prompt-fixen (labeled-triad.ts v4, deployad 2026-07-23) åtgärdade tre saker samtidigt: (a) källordning `abstract || insight` med cap 2000 tecken, (b) 5 STRICT RULES som förbjuder fabricering och tillåter ärlig generalitet, (c) techne-instruktionerna omformulerade (40–80 ord, "state only values that appear in the abstract"). Fixen är **bevisad på 3 av de 6 mest problematiska stickprovsartiklarna** (nr 2 fisksås pH, nr 3 hot pot 150°C, nr 21 getost furaner/pyraziner) — alla fabricerade siffror borta, ersatta av ärlig generalitet eller "as reported by the study".

**Slutgiltig kvalitetsbedömning kvarstår** tills batch-regenereringen (v4-prompt applicerad på hela korpusen) är klar och en NY oberoende mätning har gjorts.

---

## Mätning-design

### Urval

- **Nytt slumpurval om 25 artiklar** — *ej* samma 25 som FÖRE-mätningen (annars är resultatet inte oberoende — Anders har redan sett dem)
- Samma stratifiering: **5 per roll**, **3 st relevans ≥8 + 2 st relevans 5–7 per roll**
- Slumpa `and irrelevant is not true` (samma exkludering som batch-regenerering)
- Använd samma SQL-mall som FÖRE-mätningen (`outputs/triad-kvalitetsmatning/1-kor-detta-i-sql-editor.sql`), byt bara ID:na

### Bedömningsprotokoll (identiskt med FÖRE-mätningen)

- **Fyra fält per analys:** core_claim / Episteme / Techne / Phronesis
- **Tregradig skala:** Korrekt / Delvis / Fel
- **Feltyper:** Övertolkning / Fabricering / Missförstånd / Generisk fyllnad / Rollmissmatch
- **~5–8 min per analys**, ~3–4h totalt

### Trösklar (satta INNAN mätning, ej justerbara efter resultatet)

| Fält | Minimikrav | Motiv |
|------|-----------|-------|
| **core_claim + Episteme** | ≥ 90% Korrekt | Faktapåståenden — fel här sprider fel vetenskap |
| **Techne** | ≥ 75% Korrekt/Delvis **OCH noll fabricerade numeriska värden** | Absolut krav på fabricering — kategoriskt värre än vaghet |
| **Phronesis** | ≥ 70% Korrekt/Delvis | Mest tolkande; generisk fyllnad är svaghet, ej fara |

**Varför "noll fabricering" som absolut krav** (Anders 2026-07-23): en enda uppdiktad pH-siffra eller temperatur i produkten kan skada en användare (fel matsäkerhet, fel matlagning). Vaghet skadar inte — den bara underlevererar. Så fabricering får inte kompenseras av att andra fält är korrekta. Det ska ha ett eget veto.

---

## Beslutsmatris

| Utfall | Beslut |
|---|---|
| Alla tre trösklar uppfyllda + **noll fabricering** | **GRÖNT** — Ask/Pro kan lanseras (tillsammans med kvot + felrapporterings-UI). Copy: "AI-genererad analys av peer-reviewed forskning · stickprovsgranskad, ~9 av 10 korrekta · rapportera fel via [flagga]" |
| ≥1 tröskel underskriden ELLER minst en fabricering | **GULT/RÖTT** — analysera dominerande feltyp, iterera prompten, kör om batch, mät om. Ingen Free-lansering tills grönt |
| Extremt utfall (t.ex. Fabricering återkommer trots v4-prompten) | **RÖTT** — TRIAD-generationens grund måste omprövas (annan modell? fulltext-ingesting via Unpaywall?) |

---

## Praktisk ordning

1. **Vänta:** batchen (v4-prompt tillämpad på ~26k artiklar) är klar — script `scripts/batch-regen-triad.ts` rapporterar `ok=N, sonnet_error=..., parse_error=..., db_error=...`
2. **Slumpa 25 nya:** kör SQL-mallen (utan att ta samma IDs som FÖRE-mätningen — jämför mot `outputs/triad-kvalitetsmatning/stickprov-ids.txt`)
3. **Formatera:** Claude bygger `outputs/triad-eftermatning/4-stickprov-att-granska.md` från CSV
4. **Anders granskar:** ~3–4h, fyller i `3-granskningsmall.md`
5. **Claude räknar:** felfrekvens per fält, feltypsfrekvens, per-roll-brytning. Skriver `5-resultat-och-atgardsforslag.md`
6. **Beslut mot tabellen ovan.** Om grönt: uppdatera prismodell/lanseringschecklista med grönt-status. Om gult/rött: iterera.

---

## Bevarad baslinje

Både FÖRE- och EFTER-mätningen sparas daterade så community-verifieringen (Del B) och framtida modell-uppgraderingar kan mätas mot samma referens. Så vi kan säga *"felfrekvensen sjönk från X till Y efter prompt-fix; efter 6 månader Pro-feedback är den Z"* — vilket är själva berättelsen om produktens kvalitet över tid.
