# SPEC — Research landscape 2.0: semantisk karta med filter
**Datum:** 2026-07-15
**Status:** Beslutad riktning, EJ påbörjad. Egen byggsession (Hink 2).
**Ersätter:** dagens dekorativa cirkelvy (Explore-fliken).
**Löser:** K2.10 (ämnen ↔ keywords som filter), K2.5 (egen sida), och gör
landskapet informativt i stället för dekorativt.
**Läs tillsammans med:** gustema-kontextexport-2026-07-15.md.

---

## 0. GATE — bygget får INTE påbörjas förrän dessa är uppfyllda (2026-07-15)

Två blockerare uppmätta mot data 2026-07-15. Bygg inte förbi dem — en
karta byggd nu skulle rapportera "success" och vara halvdöd (lärdom 1).

### GATE A — embeddings-täckning per ämne (BLOCKERANDE)
Centroider kräver rimlig sample per ämne. Nuläge: ~27 % total täckning,
skevt fördelad (speglar backfill-ordning, inte ämnets tyngdpunkt — mät-
artefakt, lärdom 10). Per ämne mot tröskel ≥100 / 30–99 / <30:
- ✓ stabila (8): gastronomy 2258, fermentation 784, food_science 701,
  sensory_evaluation 189, nutritional_science 178, hospitality 153,
  uncategorized 125, sommellerie 125
- ⚠ svaga (4): flavor_science 55, multisensory 51, culinary_science 34,
  food_psychology 31
- ✗ oanvändbara (15): food_anthropology 29, appetite_research 26,
  atmospherics 10, novel_foods 10, servicescape 6, crossmodal 5,
  food_behavior 4, art_science 4, food_technology 2, m.fl.

**Gate öppnar när ≥12–14 kart-ämnen når ⚠-tröskeln** (rimligt vid
~50–60 % total täckning). generate-embeddings-cronen (*/30) betar dit
gratis — kör om Fråga 1 nästa session och jämför mot denna baslinje.

### GATE B — keyword-kolumn (LÖST OCH DEPLOYAD 2026-07-15) ✅
Verifierat mot data: **`keywords` är kanonisk (18 352 ifyllda, rik data).
`claim_keywords` var i praktiken tom (253, dead column, 0 skrivare).**
**FIXAD:** articles_public v3 exponerar nu `keywords`; frontend läser rätt
kolumn (4 ställen bytta); verifierat i browser — 18 352 keywords syns.
Kartan ska räkna keywords från `keywords`. Gate B öppen.
Kvarstår (framtida, ofarligt): migration 2c droppar claim_keywords efter
några dagars säker drift.

---

## 1. Problemet med dagens vy

Noderna står i en cirkel — positionen bär ingen betydelse. Linjerna är
oläsbara. Enda verkliga datan är nodstorlek. Vyn är en poster, inte ett
verktyg. Ingen interaktion leder någonstans.

## 2. Målbild

En 2D-karta där **avstånd betyder semantisk närhet**:
- ~16 ämnesnoder positionerade efter sitt artikelinnehåll.
- ~50–100 frekventa keywords positionerade mellan de ämnen de delar.
- Klick på keyword → filtrerar Feed på det keywordet.
- Klick på ämne → highlightar dess keywords + filtrerar Feed på ämnet.
- Kartan är en INGÅNG till sökning, inte en presentation.

Framtida koppling: K2.9 (TRIAD-dimension som filter) använder samma
filterarkitektur — tre linser på samma flöde. Bygg filtret generiskt.

## 3. Metodval (BESLUTAT 2026-07-15, med motivering)

**PCA eller klassisk MDS på cosinusavstånd, applicerad på CENTROIDER**
(ämnets/keywordets medelvektor av dess artiklars embeddings).
Testa båda, välj den som ger läsbarast karta. INTE UMAP/t-SNE.

Motivering (tre perspektiv, ovanligt samstämmiga):
- **Vetenskaplig transparens:** PCA/MDS är deterministiska, citerbara,
  förklarbara i en mening. UMAP är stokastisk + hyperparameterkänslig,
  och det finns publicerad metodkritik mot att övertolka UMAP-avstånd —
  vår publik är forskare som läser den kritiken. Kopplar till K3.4:
  aldrig översälja.
- **UX:** Vid ~100 centroid-punkter försvinner UMAP:s fördel (den lyser
  på täta rådatamoln, inte 100 punkter). Determinism = stabil layout =
  användare bygger rumsminne ("fermentation bor nere till vänster").
  En karta som möblerar om sig raserar det.
- **Kommersiellt:** Trovärdighet ÄR produkten (K3.3). Metod-fotnoten är
  en förtroendesignal konkurrenter med oförklarliga kartor saknar. Och
  den ger något att vara transparent med utan att exponera TRIAD-motorn
  (K3.1 kan avgöras oberoende).

UMAP sparas som ev. framtida experiment för ARTIKELNIVÅ-vy (450k punkter
som pekmoln) — annan produkt, annan dag.

## 4. Transparens-fotnot (del av designen, inte efterhandstillägg)

Synlig på sidan, i stil med:
> "Positioner beräknade med PCA på artiklarnas textembeddings
> (ämnen/keywords = centroider). Uppdaterad: <datum>. Avstånd ≈ semantisk
> likhet i databasens innehåll — inte fältets fullständiga karta."

Ärlig om vad kartan visar OCH inte visar (K3.4-principen).

## 5. Datamodell och beräkning

**Förberäkna allt. Frontend läser färdig payload.** (Lärdom 9: 457k-tabellen
tål inga ofiltrerade frågor; ingen tung beräkning i browsern.)

Ny tabell (via migration + CLI, aldrig SQL Editor — lärdom 7/8):

    landscape_points (
      id, kind ('topic'|'keyword'), label text, science_key text null,
      x float8, y float8,
      article_count int,          -- uppdateras ofta
      computed_at timestamptz,    -- när POSITIONEN beräknades
      refreshed_at timestamptz    -- när COUNTS uppdaterades
    )

Två rytmer, medvetet skilda:
- **Positioner:** beräknas SÄLLAN (månadsvis eller manuellt). Python-jobb
  (scikit-learn) läser embeddings → centroider → PCA/MDS → skriver x/y.
  Fast slumpfrö om MDS används. Position stabil.
  **Körmiljö (BESLUTAT):** lokalt Python-script, körs manuellt månadsvis,
  skriver via psql/service_role. Edge-stacken är Deno — ingen scikit-learn
  där. Automatisera (Modal/Fly e.d.) FÖRST när månadsrutinen fungerat
  3 månader i följd och värdet är bevisat. Scriptet ska ligga i git.
- **Counts/frekvenser:** refreshas ofta (cron, som gusto_health */10 eller
  glesare). Puls levande. En count som aldrig ändras = signal om att
  refreshen dött (lärdom 6) — lägg signal i Väktaren v5.

Keyword-urval: topp-N mest frekventa keywords över relevanta artiklar
(irrelevant=false), N ≈ 50–100.

**VARNING (lärdom 4-misstanke, funnen 2026-07-15):** frontend läser
`claim_keywords` medan pipeline skriver `u.keywords` — två olika namn.
Verifiera via information_schema FÖRE bygge:
- Finns båda kolumnerna? → en är sannolikt dead-write (klienten läser
  aldrig `keywords`). Avgör vilken som är kanonisk, städa den andra
  (samma sjuka som chip-namnrymden — två saker får aldrig heta samma sak).
- Finns bara en? → dokumentera vilken och rätta den sida som pekar fel.
Kartan ska byggas mot EN verifierad kanonisk keyword-kolumn.

## 6. Interaktion

- **Klick keyword** → Feed filtreras på keyword. URL-parameter
  (?keyword=...) så filtret är deep-linkbart (samma mönster som
  ?article=<uuid>).
- **Klick ämne** → Feed filtreras på ämne + kartans keywords för ämnet
  highlightas.
- **Hover** → count + topp-3 keywords (ämne) / topp-ämnen (keyword).
- **Aktivt filter** synligt som pill ovanför Feed, avfärgbart med ×.
- INGEN localStorage (etablerat beslut från kort-UX).

## 7. Placering (löser K2.5)

Egen route (/landscape eller under Explore som egen sida). En interaktiv
filterkarta förtjänar yta; Feed-huvudvyn rensas. Fast navigeringsmeny
(K2.2) länkar hit när den byggs.

## 8. Ingår INTE (avgränsning)

- Artikelnivå-punktmoln (450k punkter) — framtida experiment.
- Animerade övergångar mellan omräkningar — positioner byts sällan och
  då hellre med tydlig "kartan omritad <datum>" än morphing.
- Realtidsberäkning i browsern — allt förberäknat.
- TRIAD-filtret (K2.9) — samma arkitektur, egen session.

## 9. Ordningsföljd vid bygge (en session)

1. Diagnos: (a) keyword-källa — resolva claim_keywords/keywords-frågan
   (se §5-varningen); (b) embeddings-täckning PER ÄMNE. Nuläge: ~9 200
   embeddings av ~31 000 relevanta (~30 %) — generate-embeddings-cronen
   betar vidare, täckningen växer. Tröskel: ämne med <50 embeddings ger
   brusig centroid → antingen markera som "preliminär position" på kartan
   (ärligt, K3.4) eller invänta backfill för det ämnet. Räkna först,
   besluta sen.
2. Migration: landscape_points + index.
3. Python-jobb: centroider → PCA och MDS → jämför visuellt → välj → skriv.
4. Cron för count-refresh + Väktar-signal.
5. Frontend: ny route, rendering, klickfilter, fotnot.
6. Verifiera i riktig browser: klick → korrekt filtrerad Feed, deep-link
   fungerar, counts lever.

## 10. Beslutade detaljer (2026-07-15, efter Claude Code-granskning)

- **Uncategorized:** visas INTE som nod på kartan (ingen semantisk
  hemvist) men döljs inte heller — renderas som pill UTANFÖR kartan:
  "Uncategorized: N articles — click to filter". Transparens (K3.4)
  utan att förstöra kartans läsbarhet.
- **Mobil (<640 px):** ingen karta — visa filterlistan direkt (topp-16
  ämnen + topp-30 keywords, samma klickfilter, annan render). Kartan
  från tablet och uppåt. Rumsminne är en desktop-egenskap.
- **Väktaren:** signal "landscape_counts_refreshed inom X" i v5 så en
  död count-cron syns (lärdom 6).

## 11. Öppna frågor till byggsessionen

- PCA vs MDS — avgörs visuellt i steg 3 (jämför båda på riktiga
  centroider, välj läsbarast).
- Exakt tröskel/hantering för underrepresenterade ämnen — avgörs när
  per-ämne-räkningen finns (steg 1b).
