# Kravspec — Pipeline Health Monitor ("Väktaren")

## Varför (bevisat behov)
Pipelinen stannade 2026-06-30. Upptäcktes ~1 vecka senare, av en slump.
Under tiden visade appen "updated daily" (osant) och korpusen växte inte —
tyst. Farligast: cron rapporterade "succeeded" medan daily-fetch i praktiken
inte gjorde något. System dör tyst; väktaren ska fånga tyst degradering.

## Designprinciper
1. **Mät EFFEKT, inte bara körning.** Cron "succeeded" ≠ pipelinen gör något.
   Daily-fetch "lyckas" men hämtar 0 artiklar. Väktaren måste mäta faktiska
   resultat (växer korpusen? rör sig cursorer? processas kön?).
2. **Robust och oberoende.** Ska helst inte bero på samma pipeline den
   övervakar. Enkel, minimal, kör ofta.
3. **Larma UTANFÖR systemet.** Nå Anders via kanal som funkar även när
   pipelinen är nere. E-post OCH/ELLER extern uptime-tjänst som pingar en
   health-endpoint.
4. **Lågt brus.** Falsklarm gör att man slutar lyssna. Tydliga trösklar,
   larma bara på verklig degradering.

## Vad den ska övervaka (baserat på faktiska fel vi sett)

### 1. Färskhet / liveness
- max(fetched_at) i articles — om äldre än 48h → HÄMTNING DÖD.
  (Hade fångat 30/6-stoppet dagen efter.)

### 2. Hämtnings-effekt
- Antal artiklar tillagda senaste 24h / 7d. Om 0 senaste 48h → larm.
- Rör sig fetch_progress-cursorerna? (De var frusna sedan 2026-05-04.)
  max(last_run) i fetch_progress — om gammal → daily-fetch kör inte klart.

### 3. Cron-hälsa (effekt, inte bara status)
- Kör kritiska jobb (daily-research-fetch, backfill, enrichment)?
- GÖR de något? Korsa cron-succeeded mot faktisk data-förändring. Ett jobb
  som "lyckas" men inte ändrar data = tyst död (daily-fetch-fällan).

### 4. Källhälsa
- Ger varje källa (Scopus, OpenAlex, PubMed, arXiv) fortfarande data?
- Har någon tystnat (API-nyckel ute, rate limit)? Antal per källa senaste 7d.

### 5. Enrichment / processing_queue
- Fungerar TRIAD-analysen? processing_queue: växer 'done', fastnar inget i
  'processing' för länge, backar 'pending' upp orimligt?

### 6. (Bonus) Copy-sanning
- Om UI säger "updated daily", verifiera att det FAKTISKT stämmer mot
  fetched_at-ålder. Larma om copy och verklighet divergerar. (Kopplar ärlig
  kommunikation till faktisk drift.)

## Implementation (förslag)
- En edge function `health-check` som kör de ovan mätningarna mot DB och
  returnerar {status: 'healthy'|'degraded'|'down', checks: [...], details}.
- Schemalägg den (cron) t.ex. var 6:e h. Om status != healthy → skicka
  larm-mail (Brevo) till Anders med vad som är fel.
- Exponera samma health-check som en endpoint en EXTERN uptime-tjänst
  (t.ex. UptimeRobot, gratis) kan pinga — så ni får larm även om Brevo/cron
  själva är nere. Extern tjänst = oberoende övervakning av övervakaren.
- Håll den enkel. Läser nyckeltal, jämför mot trösklar, larmar. Ingen
  komplex logik som själv kan gå sönder tyst.

## Larmnivåer (förslag)
- **DOWN** (rött): hämtning död >48h, eller källa tyst, eller kö proppad.
  → omedelbart mail + extern-tjänst-larm.
- **DEGRADED** (gult): något trögt men inte dött (t.ex. en källa svag).
  → mail, ej brådskande.
- **HEALTHY** (grönt): allt rör sig. → tyst (eller valfri veckovis "allt ok").

## Ordning
Byggs EFTER att pipelinen är lagad (den ska övervaka en fungerande pipeline).
Men kravspec:en är skriven nu, medan vi färskt minns exakt vilka signaler som
felar — så väktaren bevakar rätt saker.

## Notera
Denna audit avslöjade också att SERVICE_ROLE-nyckeln funnits hårdkodad i
klartext (trigger_daily_fetch, tidigare weekly-newsletter). Väktaren löser inte
det — men rotationen av service_role (separat säkerhets-punkt) bör göras, och
väktaren bör INTE själv hårdkoda nycklar (använd vault).
