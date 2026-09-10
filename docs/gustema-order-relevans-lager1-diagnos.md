> _Arkiv — skriven under namnet Gustema, nu Gusto Science._

# ORDER — Relevans lager 1: score → ranking, inte gate. FAS 1 DIAGNOS.
**Datum:** 2026-07-17
**Beslut:** modell 2 — score RANKAR prominens, GATE:ar inte existens. Inget
blir permanent osynligt. (Se gustema-relevans-diagnos.md + redesign-spec §0.)
**Detta steg:** kartlägg VAR score används som filter kontra sortering.
**Endast läsning/kodläsning + SQL. INGEN ändring, ingen DDL, inget deploy.**

---

## MÅLET (vad "gate → ranking" betyder konkret)
Idag: 46% av artiklar (13 625) når ingen rolls tröskel (score < 5 överallt)
och blir OSYNLIGA. Vi vill att de ska vara SÖKBARA/åtkomliga — score ska
avgöra ORDNING (prominens), inte EXISTENS (om artikeln alls visas).

Men innan vi ändrar: hitta EXAKT var score fungerar som gate. Det kan sitta
på flera ställen, och de har olika konsekvenser.

---

## DEL 1 — Frontend-anropen (var filtreras flödet?)
Läs index.html. För VARJE vy som visar artiklar (Feed, Översikt, sök):
1. Vilken query/RPC hämtar artiklarna? Vilka filter skickas?
2. Finns ett `relevance_sci_* >= 5`-villkor (eller liknande tröskel) i:
   - Feed-flödet (default-vyn)?
   - Sökningen (title/author/keyword)?
   - Roll-filtret?
3. KRITISK SKILLNAD att rapportera per vy:
   - Är score ett WHERE-filter (gate: artikel visas inte alls under tröskel)?
   - Eller ett ORDER BY (ranking: alla visas, sorterade)?
   Rapportera exakt för varje vy.

## DEL 2 — RPC/DB-lagret
4. articles_public-vyn: filtrerar den redan på score, eller exponerar den
   allt (irrelevant=false)?
5. get_most_cited, match_articles, ev. feed-RPC: har de score-trösklar
   inbyggda i WHERE? (vi såg get_most_cited har filter_role med >= 5 i
   WHERE — kartlägg om fler gör det.)
6. Vilka RPC:er driver Feed respektive sök? Skiljer de sig i score-hantering?

## DEL 3 — Sökningens räckvidd (viktigast för modell 2)
7. När en användare söker (title/author/keyword) — når sökningen ALLA
   irrelevant=false-artiklar, eller bara de som passerat en roll-tröskel?
   Detta är kärnan: i modell 2 MÅSTE sök nå hela populationen.
8. Keyword-filtret (F-O8, planerat): mot vilken population körs det —
   hela DB eller redan score-filtrerat?

## DEL 4 — SQL-verifiering (kör i SQL Editor, läsfrågor)
9. Bekräfta 46%-talet + var de "osynliga" bor:
   ```sql
   select
     count(*) as total_relevant,
     count(*) filter (where
        coalesce(relevance_sci_sensory_pro,0) < 5
        and coalesce(relevance_sci_culinary_pro,0) < 5
        and coalesce(relevance_sci_gastronomy_culture,0) < 5
        and coalesce(relevance_sci_hospitality_mgmt,0) < 5
        and coalesce(relevance_sci_educator_researcher,0) < 5) as no_role
   from articles where irrelevant = false;
   ```
10. Av de "no_role": hur många har ändå keywords ifyllda (= sökbara om
    sök når dem)?
    ```sql
    select count(*) as no_role_with_keywords
    from articles
    where irrelevant = false
      and coalesce(relevance_sci_sensory_pro,0) < 5
      and coalesce(relevance_sci_culinary_pro,0) < 5
      and coalesce(relevance_sci_gastronomy_culture,0) < 5
      and coalesce(relevance_sci_hospitality_mgmt,0) < 5
      and coalesce(relevance_sci_educator_researcher,0) < 5
      and keywords is not null and array_length(keywords,1) > 0;
    ```

---

## RAPPORTFORMAT
Per vy/RPC: score som GATE (WHERE) eller RANKING (ORDER BY)?
Sammanfatta: vilka exakta ställen måste ändras för att sök/keyword ska nå
hela populationen medan feed-prominens behålls. INGEN ändring — efter kartan
skrivs Fas 2 (den faktiska ändringen), minimal och riktad.

## VIKTIGT — bevara det som funkar
Vi vill INTE göra Feed till en odifferentierad massa. Feed SKA fortfarande
rankas av relevans (prominens). Ändringen gäller att SÖK/keyword når allt,
och att inget är PERMANENT osynligt — inte att ta bort all rankning.
Skilj de två i rapporten.
