# ORDER 093 — Fixa map coverage-copy "unavailable"-racet. AUTONOM.

Repo: gastro-research. Ny gren från main.
Fortsättning på ORDER 091 §6 / ORDER 092.

## §0 Läget

Kartvyn på gusto.science visar ibland

    Institution coordinates: unavailable

trots att både `updateMapCoverageCopy()` OCH REST-endpointen den använder
fungerar. Direkt `curl` mot samma URL:

    articles_public?select=id&irrelevant=is.false&primary_institution=not.is.null
      &or=(has_episteme_sensory_pro.is.true,…,has_episteme_educator_researcher.is.true)
      &institution_coords=not.is.null&institution_coords=not.eq.%5B%5D&limit=1

med `Prefer: count=exact` returnerar `content-range: 0-0/20283` — inga fel.

Manuell re-invokation av `updateMapCoverageCopy()` från console EFTER
sidladdning skriver korrekt copy `20,283 of 28,553 TRIAD-analysed
articles with known institution — backfilling ongoing.`

Ergo: funktionen fungerar. Racet är hur den startas.

## §1 Diagnos

Två separata skrivare äger `.si-coverage`, båda kan skriva "unavailable":

**Skrivare A** — `loadWorldMapData` (rad ~6080), yttre catch (rad 6131–6135):

```js
} catch(e) {
  console.log('World map error:', e)
  const el = document.querySelector('.si-coverage')
  if(el) el.innerHTML = 'Institution coordinates: <strong>unavailable</strong>'
  return []
}
```

**Skrivare B** — `updateMapCoverageCopy` (rad ~6159), egen catch (rad 6201–6204):

```js
} catch(e) {
  console.log('coverage-copy error:', e)
  el.innerHTML = 'Institution coordinates: <strong>unavailable</strong>'
}
```

`updateMapCoverageCopy()` anropas fire-and-forget från
`loadWorldMapData` (rad 6123) utan `await`. Dessa två async-kedjor löper
parallellt och den som skriver sist vinner. När Skrivare A:s catch
fyras — även om coverage-copyns egen data lyckats — clobbras korrekt
text med "unavailable".

Att `loadWorldMapData`:s catch alls fyras är ett separat symptom
(RPC-kedjan lyckas synbart eftersom prickar renderas), men catch-
fångsten kan trigga:
- av något som kastar EFTER `updateMapCoverageCopy()` sparats
- av misslyckad `map_country_stats`/`map_institution_collabs` som inte
  gör kartan onåbar men bryter `Promise.all`
- av en `worldMapCollabs.filter`-krock om `collabRows` är `[]`

Oavsett trigger är fixen samma: **en ägare per DOM-element.**

## §2 Krav

**1. `.si-coverage` ska ägas exklusivt av `updateMapCoverageCopy`.**
Ta bort `.si-coverage`-skrivningen ur `loadWorldMapData`:s catch.
Behåll console.log:en och `return []` — de tillhör dot-data-pipelinen.

**2. Kör `updateMapCoverageCopy` oberoende av `loadWorldMapData`.**
Coverage-copyn beror bara på `articles_public`-räknare, inte på RPC:er
eller Leaflet. Den kan (och ska) fyras så tidigt som möjligt — helst
när `initWorldMap` börjar, parallellt med d3.json och loadWorldMapData.

**3. Förbättra loggen i `updateMapCoverageCopy`.**
Nuvarande `console.log('coverage-copy error:', e)` säger inte VARFÖR
fetchen misslyckas när den gör det. Logga även HTTP-status och
content-range-headern så en tyst "unavailable" går att spåra utan
network tab (samma mönster som `triad_coverage`-loggen i loadCounts
efter ORDER 092 §3).

**4. Rör inte predikatet eller copyn.**
"20,283 of 28,553 TRIAD-analysed articles with known institution —
backfilling ongoing." står fast (ORDER 091 §6 + revert).

## §3 Verifiering

Använd headless Chrome via CDP (samma script som tidigare — WebSocket +
Page.addScriptToEvaluateOnNewDocument för att bypassa onboarding-
modalen med `localStorage.setItem('gs_onboarding_seen','1')`).

Screenshot ska visa korrekt copy UTAN att någon manuell re-invocation
av `updateMapCoverageCopy` behövs.

Om copyn fortfarande visar "unavailable" — logga vad
`updateMapCoverageCopy`:s nya diagnos-print säger. Rapportera.

## §4 Rapport

- Vilken av de tre trigger-hypoteserna som visade sig stämma (om
  loggning avslöjar det)
- Vad exakt du ändrade i `loadWorldMapData` och `updateMapCoverageCopy`
- Screenshot-bevis att copyn nu skrivs korrekt vid första sidladdning
- Om ny logg avslöjar ett dolt problem — rapportera det separat,
  fixa inte

Commit per paragraf. Push.
