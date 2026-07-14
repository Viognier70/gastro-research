# Map — omdesign: världens gastronomiforskning

**Spec 2026-07-08** · Ersätter nuvarande QS-gate + roll-filter

---

## Tesen

Kartan visar **var i världen gastronomiforskning produceras** — objektivt, inte
rollfiltrerat. Feed är personlig, Map är gemensam. Det är en tydligare
arbetsfördelning än dagens, där Map försöker vara både och.

En prick per institution. **Storlek = antal publikationer.** Alla samma färg.
Ingenting annat kodas i grundvyn.

Klick på en institution → dess forskning fördelad över ämnesområden, rangordnad,
färgkodad. Där, och bara där, bär färgen information.

---

## Interaktionen

**Grundvy.** Alla institutioner. Storlek efter publikationsantal. En färg.
Inga filter aktiva.

**Klick på nod.** Panel under kartan visar:
- Institutionens namn, land, totalt antal publikationer
- Ämnesfördelning i rangordning, färgkodad (fermentation 24 · sensorik 18 · crossmodal 9 …)
- Artikellista, nyast först
- QS-rank som kontextinfo om den finns — aldrig som filter

**Ämnesfilter.** Välj ett eller flera ämnen. Då:
- **Prickarna räknas om.** Örebro krymper, Wageningen växer.
- Kartan svarar inte längre på "var forskas det" utan **"var forskas det på detta"**

Det är designens kärna. Kartan blir ett instrument, inte en illustration.

**Samarbeten.** Samma logik. Visa alla, eller bara inom valda ämnen.
*Vilka länder samarbetar om crossmodal perception?* — en fråga ingen
gastronomidatabas kan besvara idag.

---

## Vad som försvinner

**QS-gaten.** `institution_rank <= 200/500` filtrerar bort Grythyttan, Basque
Culinary Center, culinary institutes, hotellhögskolor — precis fältets kärna.
Kvarleva från när knapparna hette `top100`/`top500`; etiketterna byttes, mekaniken
blev kvar. Rank behålls i tooltip som kontext, aldrig som gate.

**Roll-filtret ("My topics").** Forskningens geografi är inte rollberoende. En
sommelier och en kock har lika stor nytta av att veta att Örebro gör
sensorikforskning. Ämnesfilter ersätter det, och gör mer.

**Färg som "huvudsakligt forskningsfält" i grundvyn.** Reducerar en institution
till ett ämne. Örebro forskar på sensorik, sommellerie, crossmodal *och*
nutrition — `dominant_topic` slår ihjäl den nyansen.

---

## Datamodellen — måste redas ut först

Två fält beskriver samma sak, fylls av olika processer, överlappar godtyckligt:

| Fält | Artiklar | Fylls av | Innehåller |
|---|---|---|---|
| `institution_coords` (jsonb) | 1 144 | `backfill-institutions` (körde på TRIAD-analyserade) | namn + lat/lng + country, per institution |
| `institutions` (text[]) | 630 | preflight 2026-07-07 + daily-fetch sporadiskt | bara namn |

För Örebro är det omvänt: 16 i `institutions[]`, 7 i `institution_coords`.
Ingen är komplett.

**Beslut:**
- **`institutions[]` räknar.** Den filtrerar, listar, dimensionerar prickar.
- **`institution_coords` placerar.** Slår upp var något ligger. Räknar aldrig.

Konsekvens: en institution utan koordinat får ingen prick, men rätt siffra
överallt där den nämns. En institution *med* koordinat dimensioneras efter sitt
verkliga publikationsantal — inte efter hur många av dess artiklar som råkade bli
koordinatberikade.

Som det är nu räknar kartan koordinater och kallar dem publikationer.

**Berikningen måste skriva båda fälten.** Gårdagens preflight skrev bara
`institutions[]`, eftersom OpenAlex inte ger geo utan separat uppslag och
`university_rankings` saknade Örebro. Koordinatkällan behöver utökas — eller
hämtas från OpenAlex `institutions[].geo` med `select=authorships` utökat.

---

## Förutsättning: datan

**Designen förutsätter en fylld databas. Den nuvarande är fylld till 0,4 %.**

- 267 066 relevanta artiklar
- 1 144 med `institution_coords`
- 630 med `institutions[]`
- Örebro: 7 respektive 16

Nodstorlek = publikationsantal är meningslöst när de flesta institutioner har
1–2 artiklar. Kartan skulle visa likformiga prickar där storleken kodar slumpen i
vilka artiklar som råkat berikas — inte var forskning bedrivs.

**Ordning:**
1. **Starta `backfill-affiliations` idag.** 3–8 veckor bakgrundsjobb, blockerar
   inget. Bevisat fungera (9/9 Scopus via OpenAlex per DOI).
2. **Bygg kartan under tiden.** ~1 dags frontend.
3. När designen är klar har datan strömmat in i veckor och prickarna betyder något.

Gör man tvärtom bygger man ett instrument och tittar på en tom himmel.

---

## Öppna designfrågor

**Skala.** Publikationsantal spänner från 1 till kanske 500. Linjär radie ger
antingen punkter eller klumpar. Kvadratrot (`r ∝ √n`) är standard för att area
ska vara proportionell mot värdet — ögat läser area, inte radie. Logaritm om
spannet blir extremt.

**Färgpalett i drill-down.** 26 ämnen är för många att skilja åt. Topp 6–8 får
egen färg, resten samlas i "övrigt". Vilka åtta? Antagligen de största i
korpusen: gastronomy · food science · nutritional science · fermentation science ·
hospitality · sensory evaluation · crossmodal · appetite research.

**Ämnesfilter-UI.** Chips? Dropdown med multi-select? Måste rymma "alla" som
default och tåla 3–4 samtidiga val utan att kartan blir obegriplig.

**Samarbetslinjer.** Kräver koordinater i båda ändar. Nuvarande trösklar
(`count >= 3`, `slice(0, 200)`) visar forskningsvärldens motorvägar, inte dess
stigar. Vid ämnesfiltrering blir underlaget mycket tunnare — kanske ingen tröskel
alls då.

**Zoom.** Streckbredden skalas idag med zoomen. `vector-effect="non-scaling-stroke"`
eller dividera med `d3.zoomTransform(svg.node()).k`.

---

## Varför detta är värt att bygga

Ingen annan gastronomidatabas svarar på *var forskas det på fermentation, och
vilka samarbetar om det*. Det är inte en visualisering av data ni råkar ha — det
är en fråga forskare ställer och inte kan besvara.

Och den gör produktens tes synlig: gastronomi är ett eget kunskapsfält med egna
institutioner. En karta som filtrerar på QS-ranking motsäger den tesen på sin
egen skärm.
