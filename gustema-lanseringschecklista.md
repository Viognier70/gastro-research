# Gustema — lanseringschecklista
**Datum:** 2026-07-16
**Syfte:** Allt som står mellan nuläget och skarp lansering, samlat.
**Källor:** kontextexport 2026-07-15 + tillägg + backlogg + tidigare sessioner.
**Princip:** BLOCKERARE (måste vara klart) skilt från NICE-TO-HAVE (kan följa efter).

---

## 🔴 PRIO 1 — SÄKERHET (blockerare, egen fokuserad session)

### L1.1 SERVICE_ROLE_KEY — DELVIS KLAR (standardisering ✅, rotation ⬜)
- Nyckeln ligger i klartext i chatthistorik + git-historik. Ger full
  läs/skriv förbi all RLS. Ska roteras oavsett lansering.
- **Faktisk komplikation (upptäckt vid genomförande 20 juli):** lästes under
  TVÅ namn — `SERVICE_ROLE_KEY` (**18 fns**, ej 10 som antogs) och
  `SUPABASE_SERVICE_ROLE_KEY` (3 fns) — plus vault för cron-triggarna.

#### L1.1a — Envar-standardisering ✅ KLAR 20 juli (commit faf752c)
- Alla 18 fns bytte `Deno.env.get('SERVICE_ROLE_KEY')` →
  `('SUPABASE_SERVICE_ROLE_KEY')`. Ren 1-radsdiff per fil.
- **Nyckel-upptäckt:** 19-juli-plattformssynken hade redan riktat in ALLA
  tre ytor (2 env + vault) på SAMMA nyckelvärde (verifierat byte-identiskt,
  SAME=YES + vault last12-match). Så ingen värde-inriktning behövdes — bara
  namnstandardisering. `secrets list`-hashar skiljde sig men var visnings-
  artefakt (HMAC/salt per secret), INTE värdeskillnad. Lärdom: de hasharna
  kan ej jämföra värden mellan olika secrets.
- **Två-grupps-redeploy** (7 fns `--no-verify-jwt`, 11 utan flagga) bevarade
  varje fns verify_jwt-status. Utan detta hade naiv deploy flippat 7 fns
  false→true = tyst 401 = 11-juli-kraschen igen. Verifierat: MISMATCHES NONE.
- **Drift verifierad:** 7/7 (senare fler) HTTP 200 efter deploy, 0 st 401.
  Stripe-webhook bevisad transitivt (identisk env-läsning som bevisade
  stripe-checkout; 0% felfrekvens; live-mode blockerar `stripe trigger`).
- Env-fallback `SERVICE_ROLE_KEY` behållen 1 vecka (till ~27 juli), städas då.

#### L1.1b — Faktisk rotation (legacy JWT → sb_secret) ⬜ KVARSTÅR (blockerare)
- **Detta är den EGENTLIGA säkerhetsåtgärden — ännu ej gjord.** Nuvarande
  nyckel är fortfarande legacy JWT (eyJh…, 219 tecken), exponerad i historik.
- Supabase mitt i JWT-migration (legacy → sb_secret_). sb_secret är INTE
  drop-in: funkar i edge-fn `createClient()` men EJ i cron/pg_net Bearer
  (kräver apikey-only header + verify_jwt=false + nyckelvalidering på
  cron-target-fns — de gamla stegen 2-6, ännu ej gjorda).
- Vault-secret refereras av 5 cron-trigger-SQL:er via `name='SERVICE_ROLE_KEY'`
  — omdöpning kräver migration-omskrivning, eget scope.
- EGEN session, utvilad. Korsar Stripe + alla backfill/pipeline/synthesize.

#### L1.1c — config.toml (deterministisk deploy) ⬜ uppföljning
- Repot saknar `supabase/config.toml` → verify_jwt lever bara i prod-state,
  ej i git. Nästa deploy utan rätt flagga kan flippa fns tyst.
- Skapa `supabase/config.toml` med `[functions.<name>] verify_jwt = false`
  för de 7: backfill-abstracts, backfill-affiliations, daily-fetch,
  health-mail, relevance-check, stripe-checkout, stripe-webhook.
- Gör deploy deterministisk, git blir källan. (I Claude Code project-memory.)

### L1.2 ANTHROPIC_API_KEY-rotation
- Exponerad i klartext i historiken. Rotera + uppdatera secret.
- Enklare än L1.1 (färre läsare), men gör den samlat med säkerhetspasset.

*(SCOPUS_KEY roterades 12 juli — avklarad.)*

---

## 🔴 PRIO 1 — INTÄKTSKEDJA (blockerare)

### L2.1 Stripe end-to-end skarpt
- Verifiera hela kedjan gratis → trial → betald i skarp miljö.
- Serverside-paywall, ingen gäst-checkout, mailbekräftelse + välkomstmail.
- (Byggd och tidigare verifierad — men kör en skarp genomkörning före lansering.)

### L2.2 Free-user-flöde
- Bekräfta att kvotdragning (3 TRIAD/månad free) ger ANALYS, inte betalvägg.
- En free-användare ska få sina 3 utan att stötas in i paywall felaktigt.

### L2.3 Städa föräldralösa profiles-rader
- 6 st noterade. Rensa före lansering.

---

## 🟡 PRIO 2 — ÄRLIG COPY / TROVÄRDIGHET (bör före lansering)

### L3.1 Skilj bredd från djup
- "453 000+ genomsökta" (bredd) ≠ "~7k djupanalyserade" (djup). Översälj inte.
- "indexed across Scopus/OpenAlex/PubMed/arXiv" ≠ "screened".

### L3.2 Ta bort "Crichton-Fock" som signup-exempel (K4.1)
- Neutralt namn i stället. Kopplat till "av forskare för forskare, inte av
  en individ" (K3.3). Enkelt + viktigt.

### L3.3 Datakvalitets-transparens (K3.4)
- Av hur många? Hur många återstår? När senast uppdaterad? Ärligt om vad
  vi levererar OCH inte levererar.

---

## 🟡 PRIO 2 — NYHETSBREV (eget block)

### L4.1 Grundfix (blockerar utskick)
- `BREVO_LIST_ID` odeklarerad → ReferenceError. Deklarera + koppla.
- Inget cron finns. Lägg schemalagt utskick.
- Testutskick (dry-run-väg + try/catch) innan skarpt.
- Subscribe-knappen är DOLD (display:none) tills detta är klart. 0 prenumeranter nu.

### L4.2 Valbar frekvens (K2.1) — NICE-TO-HAVE, ej blockerare
- 2×/vecka / veckovis / månadsvis. Bygger ovanpå L4.1. Produktförbättring,
  inte lanseringskrav.

---

## 🟡 PRIO 2 — OBSERVABILITY (blindfläckar)

### L5.1 Anthropic-kvot/400-larm i Väktaren
- Pipeline stod still 3× pga kredit-slut, felsökt manuellt varje gång.
- Ingen signal skiljer "kod trasig" från "pengar slut". Blindfläck.

### L5.2 Pipeline checkpoint-loggar
- Loggar bara boot/shutdown → gissning 4×. Lägg checkpoints.

### L5.3 Kostnadsnotis
- Höj e-postnotis $100 → ~$450 (larmar för sent nu).
- Budget: $363/500 vid 15 juli, återställs 1 aug. Auto-reload $12.50 räcker
  ej vid intensiv körning — köp klump vid behov.

### L5.4 Synthesis-larm matchar EJ pipelinens cadence (falsklarm)
- **Symptom (19 juli):** "GUSTO alert: syntheses stale 150h — cron dead or
  saving NULL". Undersökt: FALSKT LARM. Databasen frisk.
- **Rotorsak:** larmets tröskel (~larmar vid ~150h) matchar inte guardens
  faktiska cadence i synthesize-batch (hårdkodad **7 dygn = 168h**,
  index.ts rad ~33-50). Så larmet gastar varje vecka på dag 6-7 när allt
  är normalt. Larm och guard är oense om vad "stale" betyder.
- **Verifierat 19 juli:** research_syntheses har 25 rader (en per role×topic-
  combo), alla skapade 13 juli 07:15-07:20 (Anders manuella backfill efter
  fix 16511c8). Inga NULL. Cron (jobb 63, `synthesize-research`, `0 4 * * *`)
  lever och kör varje natt; guarden skippar korrekt (allt < 7 dygn) →
  38-140ms-körningar. Nästa faktiska skrivning ~20 juli 04:00 UTC.
- **ÅTGÄRD (ej brådskande, ej blockerare):**
  1. Höj larm-tröskeln till >168h (t.ex. 200h, marginal) SÅ den matchar
     7-dagars-cadencen — annars falsklarm varje vecka.
  2. ELLER, om synthesis SKA vara tätare: sänk guarden (t.ex. 24h). Se L5.5.
  Poängen: larm och guard måste dela SAMMA definition av "för gammalt".

### L5.5 BESLUT: är 7-dagars synthesis-cadence avsiktlig? (produktfråga)
- Guarden i synthesize-batch skippar topics uppdaterade < 7 dygn. Research
  Landscape ("new this week") uppdateras alltså veckovis.
- **Beslut Anders:** veckovis rimligt för "veckans forskningsläge" (tung
  LLM-analys per topic, matchar "new this week")? → guarden är rätt, justera
  bara larmet (L5.4). Eller dagligt önskat? → sänk guard till 24h.
- Kopplat: 18 av 25 combos hade < 3 artiklar med episteme_${dbRole} ifylld
  vid fix-tillfället (fick 'insufficient_articles'). Datafråga — tunn TRIAD-
  täckning för vissa role×topic? Överlappar cache-seedning inför lansering
  (prismodell-spec 425e365): just de tunna kombinationerna behöver seedas.

---

## 🔵 PRIO 3 — DOMÄNBYTE gustema.com (eget samlat projekt, checklista)

> En bruten auth-redirect/DKIM märks FÖRST när en användare inte kan logga
> in. Gör samlat, verifiera varje steg.

- DNS → Cloudflare Pages
- gustema.science + gusto.science redirect → gustema.com
- SPF/DKIM/DMARC för gustema.com
- Brevo avsändardomän GustoSci → Gustema
- Stripe checkout-domän
- **Supabase Auth redirect-URL:er** (annars bryts inloggning)
- `CANONICAL_ORIGIN='https://gustema.com'` redan satt i kod.

---

## ✅ AVKLARAT (behöver ej röras)
Elsevier/Scopus (nyckel roterad + återkallad, OpenAlex ersätter);
namnfrågan; chip-namnrymden (81 kol + CI-lint); migrationshistorik;
embeddings regenererade; kort-UX; deep-linking; Share; Citera; about-sida;
done-spöken + constraint; sci_ko v5; Map coverage-count; show-articles
namn-mismatch (delvis); **keyword-kolumnbugg (18 352 keywords live)**;
**synthesis-pipeline riktig bugg (fix 16511c8, 13 juli: anon-nyckel-bypass +
fel datakälla episteme_${chip}→${science} + INSERT→UPSERT — byggde tidigare
taggar på ~3% av korpusen; nu hela korpusen, 25 combos fyllda). OBS: senare
"stale 150h"-larm 19 juli var FALSKT, se L5.4 — ej samma sak.**

---

## ÄRLIG LÄSNING

Det tekniska maskineriet är robust. De ÄKTA lanseringsblockerarna är få:
1. **Nyckelrotationen** (L1) — säkerhet, prio 1, egen utvilad session.
   - L1.1a (envar-standardisering) ✅ KLAR 20 juli. MEN detta var bara
     förberedelsen — **L1.1b (faktisk legacy→sb_secret-rotation) KVARSTÅR**
     och är den egentliga säkerhetsåtgärden. Nyckeln är fortfarande exponerad.
   - L1.2 (Anthropic-nyckel) kvarstår.
2. **Stripe/free-flöde-verifiering** (L2) — intäkt, prio 1.
   - L2.2 free-flöde: Modell B (räkna visningar, 3/mån) byggd + verifierad.

Resten (copy, nyhetsbrev, observability, domän) är egna fokuserade block
som förbättrar men inte hårt blockerar. Ta ETT block i taget — samma
disciplin som höll done-spökena borta.

### Föreslagen ordning
1. Säkerhetspass (L1.1 + L1.2) — utvilad, egen session, korsar Stripe.
2. Intäktsverifiering (L2) — skarp genomkörning.
3. Copy-pass (L3) — snabbt, hög trovärdighetsvinst.
4. Nyhetsbrev-grundfix (L4.1) → sätt tillbaka Subscribe-knappen.
5. Väktar-blindfläckar (L5) — löpande.
6. Domänbyte (domän) — när allt ovan står stabilt.
