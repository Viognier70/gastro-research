> _Arkiv — skriven under namnet Gustema, nu Gusto Science._

# Gustema — relevans lager 1: DEPLOY-PLAN (batchning)
**Datum:** 2026-07-17
**Princip:** maximera ändringar per deploy UTAN kvalitetsbrott. Batcha det som
delar riskprofil OCH verifieringsväg; separera massdataskrivning så dess
resultat är otvetydigt (lärdom 12: destruktivt/stort får isoleras + verifieras).
**Grund:** gustema-relevans-lager1-atgardsplan.md (verifierad diagnos).

---

## REGEL FÖR BATCHNING
- Får åka ihop: ändringar som (a) testas på olika ställen så de INTE döljer
  varandras fel, (b) har jämförbar risk, (c) inte är massdataskrivning.
- Måste isoleras: massdataskrivning (13k rader) — verifieras ensam så
  resultatet inte döljs bakom samtidiga logik-ändringar.
- FÖRUTSÄTTNING: varje del verifieras för sig FÖRE deploy. Batchning gäller
  DEPLOY, inte verifiering. Aldrig batcha overifierade ändringar.

---

## DELARNA (lager 1)

| Del | Vad | Risk | Verifieras via |
|-----|-----|------|----------------|
| 1. get_most_cited-gate | Ta bort filter_role >=5 i WHERE (ranka, ej gate) | Låg | SQL + browser MOST CITED |
| 2. Framåt-fix daily-fetch | Parsa OpenAlex concepts/topics för ALLA nya artiklar → keywords | Låg-med | Ny artikel får keywords |
| 3. Re-fetch backfill | 13k no-role → OpenAlex → filtrera → skriv tomma keywords | MEDEL (13k skriv) | SQL-stickprov på resultat |

---

## DEPLOY-GRUPPER

### GRUPP A (samma deploy) — logik-ändringar
- Del 1 (get_most_cited-gate) + Del 2 (framåt-fix daily-fetch)
- Varför ihop: båda är kod/logik, INGEN massdataskrivning. Verifieras på
  OLIKA ställen (RPC-modul vs pipeline på ny artikel) → döljer inte varandra.
- Verifiering före commit:
  - Del 1: get_most_cited 200, MOST CITED visar mest citerade oavsett roll,
    ingen 400. (SQL + browser.)
  - Del 2: nästa daily-fetch-körning → nya artiklar har keywords, även
    no-role. (Kolla en ny artikels keywords efter körning.)
- Migration + pipeline-ändring i git (RPC bor i git, lärdom 13).

### GRUPP B (egen deploy) — massdataskrivning
- Del 3 (re-fetch backfill) ENSAM.
- Varför ensam: skriver 13k keyword-fält. Om level-tröskel fel, brus slinker
  in, eller keywords hamnar på fel artikel → vill se DET isolerat, inte dolt
  bakom Grupp A. Kör som eget jobb med stickprovs-verifiering EFTER.
- Verifiering efter: stickprov 20-30 backfillade artiklar — är keywordsen
  meningsfulla? Rätt artikel? Rör ej rollmärktas Haiku-keywords?
- Guard: skriv ENDAST till keywords IS NULL (no-role tomma). Idempotent —
  kan köras om utan dubbelskrivning.

---

## ORDNING
1. Verifiera + bygg Del 1 (get_most_cited). [START HÄR — lägst risk]
2. Verifiera + bygg Del 2 (framåt-fix). Bekräfta den inte döljer Del 1.
3. DEPLOY GRUPP A (Del 1 + 2 tillsammans). Verifiera båda i produktion.
4. Bygg Del 3 (re-fetch-jobb). Öppna beslut nedan avgörs här.
5. DEPLOY GRUPP B (Del 3 ensam). Stickprovs-verifiera resultatet.

## ÖPPNA BESLUT (Anders, vid Del 3-bygget)
1. Level/score-tröskel för concepts, ELLER använd topics? → stickprov med
   level+score först, Anders sätter gräns mot data.
2. Dubbel keyword-källa (Haiku precis + OpenAlex bred) eller en? Lutar dubbel.
3. Svans utan DOI (liten) — acceptera keyword-lösa. Lutar ja.

## KVALITETSGRIND (varje grupp)
Deploya INTE gruppen förrän varje del i den är verifierad för sig. Batchning
sparar deploy-cykler, men en overifierad del i en batch gör hela batchen
overifierbar (kan ej isolera vilken del som fela). Verifiera → batcha → deploy.
