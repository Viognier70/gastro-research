# ORDER — Säkerhetspass Fas 1: DIAGNOS (ingen ändring)
**Datum:** 2026-07-17
**Endast läsning/kartläggning. INGEN rotation, INGEN rename, INGEN deploy.**
**Mål:** se HELA nyckelanvändningen innan något rör:s. Rotation utan
fullständig karta = tyst JWT-krasch på cron (som 11 juli).

---

## BAKGRUND (från kontextexport)
- SERVICE_ROLE_KEY läses under TVÅ namn: `SERVICE_ROLE_KEY` (~10 fns) och
  `SUPABASE_SERVICE_ROLE_KEY` (~3 fns), plus vault för cron-triggar.
- Nyckeln ger full läs/skriv förbi all RLS. Ligger i klartext i historik.
- ANTHROPIC_API_KEY exponerad i klartext, ska också roteras.
- KÄND FÄLLA: standardisera namnet FÖRST, verifiera alla fns når nyckeln,
  SEDAN rotera. Fel ordning → cron-jobb får null-nyckel → tyst pipelinedöd.

---

## DIAGNOS — rapportera, ändra inget

### 1. SERVICE_ROLE_KEY — vem läser vilket namn
- Greppa ALLA edge functions (supabase/functions/**) efter:
  `SERVICE_ROLE_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `Deno.env.get(...)`.
- Rapportera per funktion: vilket exakt env-namn den läser.
- Räkna: hur många fns per namn. Bekräfta ~10 + ~3 eller korrigera.

### 2. Vault / cron
- Hur triggas cron-jobben? Om de använder service_role via vault
  (vault.secrets, pg_net headers, eller liknande): rapportera VAR nyckeln
  sitter och under vilket namn.
- Lista cron-jobb som skulle DÖ om service_role-nyckeln blev ogiltig utan
  att vault uppdaterades (pipeline, relevance-check, backfills, synthesize,
  health-jobb, embeddings, triad_background).

### 3. ANTHROPIC_API_KEY
- Vilka fns läser den? Under vilket namn (ANTHROPIC_API_KEY / annat)?
- Ligger den även i vault eller bara i edge-function-secrets?

### 4. Var sätts secrets idag
- Supabase-projektets secrets (via CLI/dashboard) — går de att lista via
  `supabase secrets list`? (visar NAMN, inte värden — säkert.)
- Rapportera vilka secret-namn som finns satta i projektet.

### 5. Deploy-beroende
- Om ett env-namn standardiseras: vilka fns måste RE-deployas för att
  plocka upp det nya namnet? (edge functions läser env vid cold start.)
- Finns risk att en fn körs mitt i rotation med gammalt namn?

---

## RAPPORTFORMAT
Tabell per punkt: funktion/jobb → env-namn läst → skulle dö vid rotation? (J/N)
Sammanfatta: (a) standardiserings-omfång (hur många fns byter namn),
(b) vault-beroenden, (c) deploy-ordning för säker rotation.

INGEN ändring. Efter godkänd karta skriver vi Fas 2: standardisera namn →
verifiera → rotera → verifiera cron lever. Steg för steg, verifierat mellan.
