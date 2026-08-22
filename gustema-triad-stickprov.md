# TRIAD-kvalitetsmätning — stickprov & granskningsprotokoll
**Del A i `gustema-kvalitetssakring-spec.md` · 2026-07-23**

Mål: en faktisk **felfrekvens** för de ~9 700 AI-genererade TRIAD-analyserna,
innan Ask/Pro lanseras. Utan siffran vet vi inte om produkten är 98 % eller
80 % rätt.

Beräknad tid: ~3-4 h för 25 analyser (läsa abstract + TRIAD, bedöma 4 fält).

---

## STEG 1 — Dra stickprovet

Kör i **Supabase SQL Editor**. Drar 5 artiklar per roll (25 totalt),
stratifierat över relevans så både hög- och mellanrelevanta analyser täcks.

```sql
-- TRIAD-stickprov: 5 per roll, stratifierat på relevans, slumpat inom stratum.
-- Kör HELA blocket; resultatet är 25 rader att granska.
with sampled as (
  -- sensory_pro
  (select 'sensory_pro' as roll, id, title, journal, year,
          relevance_sci_sensory_pro as relevans,
          core_claim, limitation,
          episteme_sensory_pro as episteme,
          techne_sensory_pro as techne,
          phronesis_sensory_pro as phronesis, url
     from articles
    where episteme_sensory_pro is not null
      and relevance_sci_sensory_pro >= 8
    order by random() limit 3)
  union all
  (select 'sensory_pro', id, title, journal, year, relevance_sci_sensory_pro,
          core_claim, limitation, episteme_sensory_pro, techne_sensory_pro,
          phronesis_sensory_pro, url
     from articles
    where episteme_sensory_pro is not null
      and relevance_sci_sensory_pro between 5 and 7
    order by random() limit 2)

  -- culinary_pro (Chef)
  union all
  (select 'culinary_pro', id, title, journal, year, relevance_sci_culinary_pro,
          core_claim, limitation, episteme_culinary_pro, techne_culinary_pro,
          phronesis_culinary_pro, url
     from articles
    where episteme_culinary_pro is not null
      and relevance_sci_culinary_pro >= 8
    order by random() limit 3)
  union all
  (select 'culinary_pro', id, title, journal, year, relevance_sci_culinary_pro,
          core_claim, limitation, episteme_culinary_pro, techne_culinary_pro,
          phronesis_culinary_pro, url
     from articles
    where episteme_culinary_pro is not null
      and relevance_sci_culinary_pro between 5 and 7
    order by random() limit 2)

  -- gastronomy_culture (Meal Creator)
  union all
  (select 'gastronomy_culture', id, title, journal, year,
          relevance_sci_gastronomy_culture, core_claim, limitation,
          episteme_gastronomy_culture, techne_gastronomy_culture,
          phronesis_gastronomy_culture, url
     from articles
    where episteme_gastronomy_culture is not null
      and relevance_sci_gastronomy_culture >= 8
    order by random() limit 3)
  union all
  (select 'gastronomy_culture', id, title, journal, year,
          relevance_sci_gastronomy_culture, core_claim, limitation,
          episteme_gastronomy_culture, techne_gastronomy_culture,
          phronesis_gastronomy_culture, url
     from articles
    where episteme_gastronomy_culture is not null
      and relevance_sci_gastronomy_culture between 5 and 7
    order by random() limit 2)

  -- hospitality_mgmt
  union all
  (select 'hospitality_mgmt', id, title, journal, year,
          relevance_sci_hospitality_mgmt, core_claim, limitation,
          episteme_hospitality_mgmt, techne_hospitality_mgmt,
          phronesis_hospitality_mgmt, url
     from articles
    where episteme_hospitality_mgmt is not null
      and relevance_sci_hospitality_mgmt >= 8
    order by random() limit 3)
  union all
  (select 'hospitality_mgmt', id, title, journal, year,
          relevance_sci_hospitality_mgmt, core_claim, limitation,
          episteme_hospitality_mgmt, techne_hospitality_mgmt,
          phronesis_hospitality_mgmt, url
     from articles
    where episteme_hospitality_mgmt is not null
      and relevance_sci_hospitality_mgmt between 5 and 7
    order by random() limit 2)

  -- educator_researcher
  union all
  (select 'educator_researcher', id, title, journal, year,
          relevance_sci_educator_researcher, core_claim, limitation,
          episteme_educator_researcher, techne_educator_researcher,
          phronesis_educator_researcher, url
     from articles
    where episteme_educator_researcher is not null
      and relevance_sci_educator_researcher >= 8
    order by random() limit 3)
  union all
  (select 'educator_researcher', id, title, journal, year,
          relevance_sci_educator_researcher, core_claim, limitation,
          episteme_educator_researcher, techne_educator_researcher,
          phronesis_educator_researcher, url
     from articles
    where episteme_educator_researcher is not null
      and relevance_sci_educator_researcher between 5 and 7
    order by random() limit 2)
)
select row_number() over (order by roll, relevans desc) as nr, *
  from sampled
 order by roll, relevans desc;
```

**Om något stratum ger färre än 3/2 rader** (t.ex. få 8+ för en roll): notera
det — i sig ett fynd om korpusens fördelning. Fyll på från det andra stratumet.

**Spara resultatet** (exportera CSV från SQL Editor) så du har artiklarna att
granska och kan spara bedömningarna bredvid.

---

## STEG 2 — Granska varje analys

För varje av de 25: läs **abstract/artikeln** (url-fältet), sedan TRIAD:en.
Bedöm fyra fält. Håll ~5-8 min per analys.

### Bedömningsskala
- **Korrekt** — stämmer med artikeln, inget tillagt, inget viktigt utelämnat
- **Delvis** — i grunden rätt men övertolkar, utelämnar förbehåll, eller är vag
- **Fel** — säger något artikeln inte stödjer, eller missförstår den

### Vad varje fält ska prövas mot

| Fält | Fråga att ställa |
|------|------------------|
| **core_claim** | Är detta artikelns huvudfynd, rättvisande sammanfattat? |
| **Episteme** | Håller den sig till vad artikeln *fastställer*? Övertolkning? Utelämnade förbehåll (urval, metodbegränsning)? |
| **Techne** | Är tillämpningen *härledd ur* artikeln, eller påhittad? Skulle en yrkesperson kunna följa den? |
| **Phronesis** | Situerat omdöme grundat i artikeln — eller generisk fyllnad som kunde gälla vad som helst? |

### Feltyper (notera när Delvis/Fel)
- **Övertolkning** — säger mer än artikeln stödjer
- **Fabricering** — specifika värden/protokoll/siffror som inte finns i artikeln
- **Missförstånd** — har läst artikeln fel
- **Generisk fyllnad** — inget artikelspecifikt sägs
- **Rollmissmatch** — analysen passar inte yrkesrollen den gjorts för

---

## STEG 3 — Granskningsmall

Fyll i per analys (kopiera raden 25 gånger, eller använd kalkylark):

```
Nr | Roll | Artikel-id (kort) | core_claim | Episteme | Techne | Phronesis | Feltyp(er) | Notering
---|------|-------------------|------------|----------|--------|-----------|------------|----------
 1 |      |                   |            |          |        |           |            |
 2 |      |                   |            |          |        |           |            |
```

Exempel på ifylld rad:
```
 7 | culinary_pro | 3f2a… | Korrekt | Delvis | Fel | Delvis | Fabricering (techne anger 62°C, finns ej i artikeln); Övertolkning (episteme utelämnar att n=12) | Artikeln är pilotstudie, analysen framställer den som etablerad
```

---

## STEG 4 — Räkna ut felfrekvensen

Per fält, över alla 25:

```
core_claim:  __ Korrekt / __ Delvis / __ Fel  → __ % korrekt
Episteme:    __ Korrekt / __ Delvis / __ Fel  → __ % korrekt
Techne:      __ Korrekt / __ Delvis / __ Fel  → __ % korrekt
Phronesis:   __ Korrekt / __ Delvis / __ Fel  → __ % korrekt
```

Plus: **vanligaste feltyp** och **om någon roll sticker ut** (t.ex. om
hospitality_mgmt har fler fel — kanske tunnare underlag där).

---

## STEG 5 — Beslut

**Förslag på tröskel** (din bedömning som forskare avgör):

| Fält | Minimikrav | Motiv |
|------|-----------|-------|
| core_claim + Episteme | **≥90 % Korrekt** | Faktapåståenden — fel här sprider fel vetenskap |
| Techne | ≥75 % Korrekt/Delvis | Tolkande, men får ej fabricera protokoll |
| Phronesis | ≥70 % Korrekt/Delvis | Mest tolkande; generisk fyllnad är svaghet, ej fara |

**Om under tröskeln** — åtgärder i ordning:
1. Skärp TRIAD-prompten mot vanligaste feltypen (t.ex. "ange aldrig numeriska
   värden som inte står i artikeln")
2. Höj relevanströskeln för vilka artiklar som analyseras
3. Byt/uppgradera modell för generering
4. Begränsa lansering till de roller där kvaliteten håller

**Om över tröskeln** — lansera, men med copy som matchar mätningen:
t.ex. "AI-genererad analys av peer-reviewed forskning · stickprovsgranskad,
~9 av 10 korrekta · rapportera fel via [flagga]". Ärlighet om en känd
felfrekvens är starkare än tystnad.

---

## Anteckning
Resultatet blir också **baslinjen** som community-verifieringen (Del B) mäts
mot: förbättras felfrekvensen när medlemmar börjar flagga? Spara mätningen
daterad så den går att jämföra om 6 månader.
