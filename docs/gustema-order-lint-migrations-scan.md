> _Arkiv — skriven under namnet Gustema, nu Gusto Science._

# ORDER — utöka lint-role-columns.sh att skanna migrations/
**Datum:** 2026-07-16
**Rot:** lärdom 7 (RPC utanför git osynlig) + lärdom 11 (mät hela mängden)

## Bakgrund
Fram till 2026-07-16 bodde 8 RPCer bara i Supabase SQL Editor, utanför
git. `scripts/lint-role-columns.sh` (från c84dc9b) exkluderar uttryckligen
`supabase/migrations/` och kunde per definition inte se dessa RPCer.
Följden: `get_most_cited` bar `relevance_sci_sommelier` sedan chip-
drop 2026-07-13 och returnerade 400, men lint kunde inte flagga det.

Migration 20260716120000 adopterar alla 8 RPCer i git. Därmed kan
lint nu skanna dem — hålet stängs.

## Åtgärd
1. `scripts/lint-role-columns.sh`, rad ~28: ta bort `supabase/migrations/`
   ur exkluderingen i FILES-genereringen. Behåll `node_modules/` och
   `scripts/` (skanna inte lint-scriptet mot sig självt).
2. Verifiera att befintliga migrationer inte ger falska träffar.
   Historiska DROP-migrationer (20260713140100) och pre-drop-skapare
   (20260704120000, 20260707120000) refererar chip-namn avsiktligt.
   Antingen:
   - Exkludera exakta filnamn med känd historisk kontext (lista i scriptet)
   - Eller: bara skanna nya migrationer via `git diff --name-only` mot main
   Rekommendation: senare — lint på diff:en, inte hela trädet, för denna
   populationsklass. Ger bättre signal-till-brus.
3. Uppdatera doc-header i lint-scriptet: "skannar nu även migrations/
   (för RPCer). Historiska drop/create-migrationer är exkluderade
   via allowlist / diff-scope."
4. Wire in i pre-commit + CI (redan gjort — inga nya steg).

## Verifiering
- Skapa test-migration som interpolerar `relevance_sci_sommelier` i en
  RPC-def. Kör lint. Ska fail:a.
- Ta bort test-migrationen.
- Kör lint på HEAD. Ska pass:a (befintliga migrationer clean efter
  20260716120000).

## Blockerar inte
Denna order kan tas när som helst. Migration 20260716120000 fungerar
utan lint-utökningen; utökningen skyddar bara mot FRAMTIDA återfall.
Låg brådska, hög värde.
