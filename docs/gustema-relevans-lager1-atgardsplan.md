> _Arkiv — skriven under namnet Gustema, nu Gusto Science._

# Gustema — relevans lager 1: åtgärdsplan (verifierad)
**Datum:** 2026-07-17
**Status:** Diagnos KOMPLETT och verifierad. Bygge = nästa session.
**Kostnad:** GRATIS i budget (OpenAlex gratis, noll Haiku). ~2-3 min körtid.
**Läs med:** gustema-relevans-diagnos.md, redesign-spec §0 (modell 2).

---

## DIAGNOS-RESA (vad vi trodde vs vad som gällde)
Sex hypoteser, var och en avfärdad/bekräftad av data (INTE gissning):
1. "46% osynliga i Feed" → FEL. Feed visar alla, sorterat på datum.
2. "Sökning når inte allt" → FEL. Titel/författar-sök når hela populationen.
3. "keyword-gen gate:as bakom roll" → FEL. Keyword-steget är oberoende.
4. "bara gamla artiklar saknar keywords" → DELVIS. Även nya no-role saknar.
5. "keywords ligger i claim_keywords, kopiera" → FEL. 0/13628, borta.
6. "concepts bevarade i raw_data-JSONB" → FEL (Anders/assistent-premissfel,
   Claude Code fångade). raw_data finns inte i DB.
→ SANT: no-role-artiklar får aldrig keywords; OpenAlex concepts/topics kan
   re-fetchas gratis (data finns i OpenAlex API, ej lokalt).

## VERKLIG MEKANISM
- No-role-artiklar (score <5 på alla 5 roller) = 13 628 av 32 189 (~42%).
- De VISAS i Feed (ej osynliga) men saknar: TRIAD-analys, rollmärkning,
  OCH keywords (0 av 13 628 har keywords).
- Utan keywords kan de aldrig nås av keyword-linsen (F-O8) = modell 2:s kärna
  fungerar bara på 58% av materialet.
- Anders nyckelfråga: pipeline betalar Haiku för keyword-gen medan OpenAlex
  REDAN ger concepts/topics gratis i fetch — men pipeline kastar dem.

---

## ÅTGÄRDER (bygg i denna ordning, nästa session)

### 1. get_most_cited-gate (en rad, gratis)
RPC har `filter_role ... >= 5` i WHERE → MOST CITED gömmer artiklar under
tröskel. Ta bort score-gaten så MOST CITED visar mest citerade OAVSETT roll.
(Score som ranking, inte existens-gate — modell 2.) Migration i git.

### 2. OpenAlex re-fetch backfill (~660 anrop, gratis, ~2-3 min)
- Målgrupp: ~13k no-role-artiklar MED DOI (svans utan DOI kan ej re-fetchas,
  förblir titel-sökbara — acceptabelt).
- Hämta BÅDE `concepts` (level/score) OCH `topics`/`keywords` (nyare, renare)
  per DOI. Jämför vilket ger bäst navigerings-keywords.
- Filtrera: concepts level >=2 + score-tröskel (Anders sätter efter stickprov),
  ELLER topics rakt av om de är renare.
- Skriv ENDAST till tomma keywords-fält (no-role). Rör INTE rollmärkta
  artiklars Haiku-keywords (verifierat säkert).
- Batcha mot OpenAlex rate limit. Gratis (OpenAlex tar ej betalt).

### 3. Framåt-fix i daily-fetch (pipeline, gratis)
- Parsa OpenAlex concepts/topics för ALLA nya artiklar, skriv till keywords —
  oavsett om de når en roll. Stoppar blödningen (nya no-role får keywords).
- Beslut: behåll Haiku-keywords OCKSÅ (precis, för sökning) + OpenAlex-topics
  (bred, för navigering)? Eller ersätt? Anders väger — dubbel källa ger både
  precision och orientering (strategi 2 från diskussionen).

---

## ÖPPNA BESLUT (Anders, före/under bygge)
1. Level/score-tröskel för concepts — ELLER använd topics i stället?
   Kräver stickprov med level+score per concept (kör i bygg-session).
2. Framåt: dubbel keyword-källa (Haiku + OpenAlex) eller en? Dubbel ger
   precision + bredd, men mer datamodell. Lutar mot dubbel.
3. Svansen utan DOI (liten grupp) — acceptera keyword-lösa, eller separat
   lösning? Lutar acceptera (titel-sökbara ändå).

## VAD DETTA INTE ÄR
- INTE Haiku-regenerering (dyrt, onödigt — OpenAlex ger gratis).
- INTE en Feed-osynlighetsfix (Feed gate:ar inte — det var fel hypotes).
- INTE en pipeline-arkitekturomskrivning (keyword-steget är redan oberoende).

## LÄRDOM FRÅN DIAGNOSEN
Assistent byggde 3 steg på premissen "raw_data-JSONB finns" utan att
verifiera kolumnen existerade. Claude Code fångade det före queries failade.
Lärdom: verifiera premissen mot schema INNAN flera steg byggs på den. Även
diagnos-antaganden ska bekräftas, inte bara fix-antaganden (lärdom 10 gäller
uppåt i kedjan, inte bara vid fix-ögonblicket).

## KOSTNAD SAMMANFATTAD
get_most_cited: gratis. Re-fetch 13k: gratis (OpenAlex), ~2-3 min. Framåt-fix:
gratis. HELA lager 1 kostar noll budget. Anders "Haiku dubbelt?"-fråga
förvandlade ett 13k-Haiku-budgetbeslut till en gratis migration.
