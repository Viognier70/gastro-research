-- =====================================================================
-- alert_log — cooldown-tabell för health-alert SMS
-- =====================================================================
-- En rad per larmtyp. alert_type är PK. last_sent uppdateras när ett
-- SMS faktiskt går ut (edge-fn upsertar med now()). Cooldown-check i
-- edge-fn: skicka inte om last_sent > now() - interval '24 hours'.
--
-- Skrivningen sker FÖRE sms-anropet returnerar? Nej — mönstret här är
-- "send-then-mark": edge-fn skickar först, upserar last_sent bara vid
-- HTTP 2xx från Brevo. Motiv: om Brevo tokar ut vill vi kunna larma
-- igen nästa cron-tick (30 min). Nackdel är teoretisk race mellan två
-- parallella invocations — cron */30min gör det i praktiken omöjligt,
-- och manuell test-trigger sker medvetet.
--
-- Endast service_role (edge-fn) skriver/läser. RLS på med tomma
-- policies -> anon/authenticated stängs ute. Service role kringgår
-- RLS.
-- =====================================================================

create table if not exists public.alert_log (
  alert_type text primary key,
  last_sent  timestamptz not null default now()
);

alter table public.alert_log enable row level security;

revoke all on table public.alert_log from public, anon, authenticated;

-- =====================================================================
-- Verifiering:
--   select * from public.alert_log;                 -- initialt tomt
--   -- efter första utskick:
--   select alert_type, last_sent, now() - last_sent as age
--     from public.alert_log;
-- =====================================================================
