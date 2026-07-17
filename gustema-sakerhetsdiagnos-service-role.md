# Gustema — säkerhetsdiagnos: service_role-standardisering
**Datum:** 2026-07-17
**Status:** DIAGNOS KOMPLETT. Fas 2 (rotation) EJ påbörjad — egen utvilad session.
**Slutsats:** Latent drift-bomb, INTE aktiv brand. Rotation kan tas metodiskt.
**Modus:** Autentiseringslagret — ~25 modifieringar. Trött misstag tar ner allt.
Verifiera mellan varje steg. Aldrig en trött kväll.

---

## SLUTSATSEN FÖRST

Två service_role-secrets har driftat isär (lärdom 4 på auth-nivå):
- `SERVICE_ROLE_KEY` (manuell, 2026-06-11) — **stale snapshot**, läses av 15 fns
- `SUPABASE_SERVICE_ROLE_KEY` (auto-managed av Supabase, 2026-07-15) — läses av 3 fns
- Vault har en TREDJE kopia under namn `SERVICE_ROLE_KEY`, läst av 9 cron-jobb.

**Är split-brain aktivt? NEJ.** net._http_response senaste 6h (530 anrop):
476× 200, 0× 401/403. Den stale nyckeln LEVER — annars vore 401 överallt
(pipeline kör var 3:e min). → Latent bomb, planerad rotation, inte akut.

**Reservation:** pg_net-loggen täcker bara ~6h (rensas aggressivt). "Inga 401"
är starkt (hög volym) men inte 100%. Vill man ha 24h+ säkerhet: dashboardens
edge-function-loggar går längre bak. Bedömning: 530 rena anrop räcker.

---

## NYCKELMODELL (viktigt — ändrar bilden)

Projektet är på Supabases NYA nyckelmodell: `sb_publishable_` + `sb_secret_`,
INTE gamla anon/service_role-JWT. Dashboard Secret keys visar:
default, supabase_service_role_key (sb_secret_8rBEj…), anthropic_api_key
(sb_secret_IKNpn…), stripe_secret_key, stripe_webhook_secret — alla maskerade.

Docs bekräftar: SUPABASE_SERVICE_ROLE_KEY + SUPABASE_ANON_KEY är märkta
"Legacy". Framtiden är publishable/secret-modellen. → Denna rotation stänger
NUVARANDE drift. En SENARE migration (legacy → publishable/secret) är eget
projekt, ~6–12 mån, scopas separat. Gör INTE båda nu.

---

## KARTAN — vem läser vad

### SERVICE_ROLE_KEY (stale, manuell) — 15 edge-fns
backfill-abstracts, backfill-affiliations, backfill-institutions, daily-fetch,
health-alert, health-mail, pipeline, relevance-check, stripe-checkout,
stripe-webhook, synthesize, synthesize-batch, triad-background, triad-on-demand,
weekly-newsletter

### SUPABASE_SERVICE_ROLE_KEY (auto-managed) — 3 edge-fns
generate-embeddings, semantic-search, welcome-email

### Ingen service_role — 1 fn
newsletter-signup (bara BREVO_API_KEY)

### Vault (namn SERVICE_ROLE_KEY) — 9 cron-jobb
Direkta (5): pipeline-every-5min (*/3), relevance-check-job (varje min),
backfill-institutions-hourly, generate-embeddings-30min, synthesize-research.
Indirekta via trigger-fn (4): daily-research-fetch, health_alert_30m,
health_mail_daily, triad_background_30m.

### ANTHROPIC_API_KEY — 6 fns, ett namn, ingen vault
daily-fetch, pipeline, relevance-check, synthesize, triad-background,
triad-on-demand. Ligger i edge-secrets, ej vault. Cron behöver den ej
(edge-fn läser egen env). Enklare rotation — gör separat/efter service_role.

---

## STRATEGI — Alt A (standardisera på auto-managed)

**Skrota den manuella SERVICE_ROLE_KEY. Alla läser SUPABASE_SERVICE_ROLE_KEY
(Supabase-kanonisk, auto-managed).** Då: en källa, Supabase-synkad, driften
kan aldrig återuppstå. Alt B (behålla manuell) lämnar drift-bomben kvar.

Blast radius: ~25 ändringar = 15 edge-fns + 5 direkta cron + 4 trigger-fn
+ 1 orphan-adoption.

---

## FÖRBEREDELSE (INNAN rotation) — kritiskt

**trigger_triad_background() är en MISSAD orphan-RPC** (utanför git). Gårdagens
adopt_orphan_rpcs-migration missade den (letade bara .rpc()-callers, ej
cron→trigger-kedjan). MÅSTE adopteras till git FÖRST — annars kan vi inte
säkert modifiera den vid namn-standardisering. Verifiera samtidigt att
trigger_daily_fetch(), trigger_health_alert(), trigger_health_mail() finns
i git och matchar live (pg_get_functiondef).

---

## FAS 2 — SÄKER ROTATIONS-ORDNING (utvilad session)

Verifiera mellan VARJE steg. Detta är auth — halvgjort = tyst produktionsdöd.

1. **Adoptera orphan-trigger-fns** till git (trigger_triad_background m.fl.).
   Verifiera alla 4 trigger-fns i git matchar live.
2. **Standardisera env-namn:** ändra 15 edge-fns från `SERVICE_ROLE_KEY` →
   `SUPABASE_SERVICE_ROLE_KEY`. (De 3 läser redan rätt.)
3. **Uppdatera vault + cron/trigger:** 5 direkta cron + 4 trigger-fns byter
   vault-lookup till samma namn/nyckel. Vault-secret pekar på auto-managed.
4. **Deploya samtliga 15 rörda edge-fns.** Verifiera med test-invocation att
   auth funkar (pipeline manuellt → 200, inte 401).
5. **Verifiera cron lever:** vänta 60s cold-start-cykling, kolla
   net._http_response → fortsatt 200, inga nya 401.
6. **Radera stale manuell SERVICE_ROLE_KEY** ur secrets + vault — FÖRST när
   allt verifierat läser auto-managed. (Detta stänger driften definitivt.)
7. **Efter 24h utan incident:** bekräfta i loggar att inga 401 uppstått.

**Rollback-plan:** om steg 4/5 visar 401 — återställ env-namn till
SERVICE_ROLE_KEY på de fns som failade, re-deploya, undersök innan nytt försök.
Radera INTE stale nyckeln (steg 6) förrän 4+5 är gröna.

---

## ANTHROPIC_API_KEY-rotation (separat, enklare)
6 fns, ett namn, ingen vault. Rotera efter service_role är klar:
ny nyckel i Anthropic-konsolen → uppdatera Supabase-secret → re-deploya 6 fns
→ verifiera pipeline gör Haiku-anrop utan 401. Ingen cron/vault-komplikation.

---

## BIFYND (ej auth, ej blockerande — egen liten uppföljning)
Ur net._http_response senaste 6h:
- **45 NULL-statuskoder** (~8,5%): anrop utan HTTP-svar — timeout/anslutningsfel
  (kolla `timed_out`-kolumn). Vilken fn? Tung fn som ibland överskrider timeout?
- **10× 500** klumpade ~08:00: skur av interna fel i någon edge-fn, ej spritt.
  Troligen ett jobb som failade några ggr i rad. Kolla `content`/`error_msg`.
Notera, jaga inte nu (spretar). Egen diagnos om de kvarstår.

---

## PROCESSNOT
Diagnos-sessionen hade tre falska alarm (Stripe-nyckel "exponerad" i
skärmdump — visade sig maskerad; curl-test 401/401 — tomma variabler; curl
platshållartext). Alla tre rätt att stanna vid och verifiera bort. Lärdom:
manuell nyckelhantering i terminal är felbenäget OCH ökar exponering — den
indirekta produktionslogg-vägen (net._http_response) svarade på rätt fråga
utan att röra ett enda nyckelvärde. Använd den vägen i Fas 2-verifieringen med.

Fas 2 = egen utvilad session. Öppna INTE en 25-stegs auth-rotation trött.
