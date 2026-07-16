# Gustema — lanseringschecklista
**Datum:** 2026-07-16
**Syfte:** Allt som står mellan nuläget och skarp lansering, samlat.
**Källor:** kontextexport 2026-07-15 + tillägg + backlogg + tidigare sessioner.
**Princip:** BLOCKERARE (måste vara klart) skilt från NICE-TO-HAVE (kan följa efter).

---

## 🔴 PRIO 1 — SÄKERHET (blockerare, egen fokuserad session)

### L1.1 SERVICE_ROLE_KEY-rotation ⚠️ VIKTIGAST
- Nyckeln ligger i klartext i chatthistorik + git-historik. Ger full
  läs/skriv förbi all RLS. Ska roteras oavsett lansering.
- **Komplikation:** läses under TVÅ namn — `SERVICE_ROLE_KEY` (10 fns) och
  `SUPABASE_SERVICE_ROLE_KEY` (3 fns) — plus vault för cron-triggarna.
- **Ordning (får ej slås ihop):**
  1. Standardisera envar-namnet i egen commit (→ SUPABASE_SERVICE_ROLE_KEY,
     Supabase-standard). Verifiera att ALLA 13 fns når nyckeln.
  2. SEDAN rotera. Uppdatera alla secrets + vault. Verifiera cron-triggar
     lever (annars tyst JWT-krasch → pipelinedöd, som 11 juli).
- Korsar Stripe-checkout/webhook + alla backfill/pipeline/synthesize.
  EGEN session, utvilad — aldrig en trött kväll.

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
namn-mismatch (delvis); **keyword-kolumnbugg (18 352 keywords live)**.

---

## ÄRLIG LÄSNING

Det tekniska maskineriet är robust. De ÄKTA lanseringsblockerarna är få:
1. **Nyckelrotationen** (L1) — säkerhet, prio 1, egen utvilad session.
2. **Stripe/free-flöde-verifiering** (L2) — intäkt, prio 1.

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
