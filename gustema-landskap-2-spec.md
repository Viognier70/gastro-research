# SPEC — Research landscape 2.0: semantisk karta med filter
**Datum:** 2026-07-15
**Status:** Beslutad riktning, EJ påbörjad. Egen byggsession (Hink 2).
**Ersätter:** dagens dekorativa cirkelvy (Explore-fliken).
**Löser:** K2.10 (ämnen ↔ keywords som filter), K2.5 (egen sida), och gör
landskapet informativt i stället för dekorativt.
**Läs tillsammans med:** gustema-kontextexport-2026-07-15.md.

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
- **Counts/frekvenser:** refreshas ofta (cron, som gusto_health */10 eller
  glesare). Puls levande. En count som aldrig ändras = signal om att
  refreshen dött (lärdom 6) — lägg signal i Väktaren v5.

Keyword-urval: topp-N mest frekventa keywords över relevanta artiklar
(irrelevant=false), N ≈ 50–100. Exakta källkolumnen för keywords
fastställs vid diagnos (verifiera mot DB innan bygge — lärdom 10).

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

1. Diagnos: keyword-källa i DB, embeddings-täckning per ämne (verifiera
   att alla ~16 ämnen har nog artiklar med embedding för stabil centroid).
2. Migration: landscape_points + index.
3. Python-jobb: centroider → PCA och MDS → jämför visuellt → välj → skriv.
4. Cron för count-refresh + Väktar-signal.
5. Frontend: ny route, rendering, klickfilter, fotnot.
6. Verifiera i riktig browser: klick → korrekt filtrerad Feed, deep-link
   fungerar, counts lever.

## 10. Öppna frågor till byggsessionen

- Exakt keyword-kolumn/källa i articles (fastställs i steg 1).
- PCA vs MDS — avgörs visuellt i steg 3.
- Ska "uncategorized" visas på kartan eller döljas? (Ärlighet talar för
  att visa den, K3.4 — men den har ingen semantisk hemvist.)
- Mobilanpassning: kartan kräver yta — separat mobilläge eller lista?
