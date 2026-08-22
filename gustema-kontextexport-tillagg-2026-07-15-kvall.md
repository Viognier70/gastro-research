> _Arkiv — skriven under namnet Gustema, nu Gusto Science._

# Kontextexport — TILLÄGG 2026-07-15 (sen kväll)
**Klistras in i gustema-kontextexport-2026-07-15.md (§3 + §8 + §5).**
**Sessionen efter kontextexporten: Explore-UX + Hink 1-buggar.**

---

## Tillägg till §3 — DENNA SESSIONS ARBETE (Explore + Hink 1)

### Klart och verifierat
- **K1.1a/b kartan (Map-vyn):** live-täckningsräknare ersatte inbakad
  "89 of 1,809" (commit fd69e55). Räknaren växer med backfill.
- **K1.1c show articles namn-mismatch (commit cdc2e57):** filtret slog
  `institutions cs {X}` med JSONB-namnet (engelsk OpenAlex-form), men
  institutions[] bär lokal form → 0 träffar. Ex: Karolinska = 749 i
  institutions[] (svensk "Institutet") vs 6–12 i coords ("Institute").
  Fix: OR mot båda kolumnerna → markören matchar minst sig själv.
  **DELVIS verifierad i browser (KTH-markör gav 6 art.), men se ny bugg.**
- **KEYWORD-KOLUMNBUGG LAGAD OCH DEPLOYAD ✅:** `keywords` (18 352, rik
  data) var kanonisk men frontend läste tomma `claim_keywords` (253, dead
  column, 0 skrivare) → produkten visade ~0 keywords i månader (lärdom
  4+5; `|| []`-fallback gjorde den tyst). Fix: articles_public v3
  exponerar keywords; 4 frontend-rader bytta (rad 2282 renderare + 3
  FIELDS-strängar). **Verifierat i browser — 18 352 keywords syns nu.**
  Kvar: migration 2c droppar claim_keywords efter några dagars drift.

### NYA KÄNDA BUGGAR (upptäckta denna session, EJ lagade)

- **INSTITUTION_COORDS 62× under-coverage:** Karolinska 749 i
  institutions[] vs 12 i coords. Kartan (Map) underrepresenterar
  systematiskt icke-anglosaxiska institutioner — backfill-institutions
  har bara nått en bråkdel. Kräver namn-unifiering + full omberikning
  (coords ska bära SAMMA sträng som institutions[]). EGEN order, ej
  skriven än.
- **MISSTÄNKT coords-feltilldelning (OVERIFIERAD):** KTH-markören visade
  en artikel om sugar kelp fermentation (Stévant m.fl.) som ser
  nordisk/norsk ut, ej självklart KTH. Om coords knyter FEL institution
  till artikel är det allvarligare än namn-mismatchen. VERIFIERA nästa
  session: för artiklar med KTH i coords — står KTH även i deras
  institutions[]? Rapportera art-id + båda kolumnerna. Ingen fix förrän
  mekanismen bekräftad (lärdom 10).

### Kvarvarande Hink 1 (ej klart)
- **K1.5 färger:** TRE parallella färg-defs (rad 3446 Explore, 5105
  worldMap, 5132 popup), medveten femklustring men divergerande paletter
  → samma topic får olika färg på olika ytor. BESLUT KRÄVS: (A) unik
  nyans inom klusterfamilj, eller (B) strikt unik per topic. Sedan
  konsolidera till EN shared const. Fas B ligger i
  gustema-order-hink1-slutstadning.md.
- **K1.3 favicon:** verifiera i browser ljust+mörkt (ej gjort).
- **K1.4 layout-blink:** DevTools Layout Shift (ej gjort). Misstänkt:
  font display=swap (rad 74) eller feed-container utan reserverad höjd.
- **B5 title-tagg:** grep "Gusto Science" i index.html meta-taggar.

---

## Tillägg till §8 — Att göra

### Explore/Research landscape 2.0 (PCA-karta) — SPEC KLAR, GATAD
`gustema-landskap-2-spec.md` sparad i repo. Bygget GATAT tills:
- GATE A: embeddings-täckning ≥12–14 kart-ämnen över ⚠-tröskel
  (nu: 8 stabila / 4 svaga / 15 för tunna; ~27 % total). Kör om Fråga 1
  nästa session, jämför baslinje. generate-embeddings betar dit gratis.
- GATE B: keyword-kolumnbuggen lagad (keywords exponerad i view).
Bygg INTE förbi gaten — halvdöd karta rapporterar "success" (lärdom 1).

### Nya order-filer denna session
- gustema-order-keyword-kolumnfix.md (keyword-bugg, lagas snart)
- gustema-order-hink1-slutstadning.md (Fas B: färger, title, counts)
- gustema-landskap-2-spec.md (PCA-karta, gatad)

---

## Tillägg till §5 — Väktaren (blindfläckar)

- **landscape_counts_refreshed-signal** ska in i v5 när PCA-kartan byggs
  (två rytmer: position sällan, count ofta — död count-cron måste synas,
  lärdom 6).

---

## PROCESSNOT (till nästa session)

Denna session spretade över många trådar (Explore-spec + 4–5 kart-buggar
samtidigt) — samma mönster som födde done-spökena. Nästa session: EN
tråd i taget. Föreslagen ordning:
1. K1.5 färgbeslut A/B + konsolidering till EN shared const.
2. Verifiera coords-feltilldelning (KTH) — kan vara allvarlig.
3. Institution namn-unifiering (backfill) + 62×-täckningen.
4. K1.3 favicon, K1.4 blink, B5 title-tagg (småfixar, bakas in).
KLART denna session: keyword-kolumnfixen (deployad, verifierad).
PCA-kartan väntar på GATE A (embeddings ~27 %); GATE B nu öppen.

Anon-curl duger INTE för DB-diagnos av kolumner utanför articles_public
(blind för allt vyn ej exponerar). SQL Editor för läsfrågor är default;
curl undantag. (Bet 2× denna session.)
