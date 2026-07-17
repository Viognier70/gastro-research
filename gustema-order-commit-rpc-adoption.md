# ORDER — commit RPC-adoption (migration + frontend tillsammans)
**Datum:** 2026-07-16
**Verifierat:** SQL (5 frågor grön) + browser (konsol ren, MOST CITED rik,
RESEARCH PULSE 9 408 artiklar, färgpalett distinkt).

---

## COMMIT — allt i EN commit

```
git add supabase/migrations/20260716120000_adopt_orphan_rpcs.sql \
        index.html \
        gustema-order-lint-migrations-scan.md

git commit -m "fix(rpc): adoptera 8 orphan-RPCer till git + laga get_most_cited chip-bugg + keyword-kolumn

- get_most_cited: 5 droppade chip-namn (relevance_sci_sommelier m.fl.)
  → science-namn. filter_keyword: claim_keywords → keywords.
- get_trending_keywords: claim_keywords → keywords (253 → 18 352 rader).
- Frontend rad 2849: body.filter_role = toDbRole(role) (samma commit,
  annars bryts get_most_cited åt andra hållet).
- 6 övriga RPCer adopterade oförändrade.
- Lärdom 7: RPCer bodde utanför git, osynliga för lint. Nu i git."
```

## KRITISKT — bekräfta före push
1. `git show --stat HEAD` efter commit: index.html MÅSTE vara med.
   toDbRole-editen (rad 2849) får INTE hamna utanför commiten — annars
   är frontend och RPC osynkade i git.
2. Rapportera commit-hash.
3. Döda lokala servern: `pkill -f "http.server 8000"`.

## EFTER
- CF bygger automatiskt vid push. Verifiera get_most_cited på PRODUKTION
  (gusto.science) när bygget är klart — samma check: konsol ren, MOST
  CITED laddar, ingen 400/42703. (Du, senare.)
- Migrationen är redan applicerad mot Supabase (db push tidigare), så
  produktions-RPC:n är redan fixad — detta committar bara koden till git.
