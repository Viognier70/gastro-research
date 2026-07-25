# Supabase — konventioner för det här repot

## Anon-grants: nya tabeller ger 401 tills explicit grant

Från och med `20260725130000_security_rls_grants.sql` gäller:

```sql
alter default privileges for role postgres in schema public
  revoke insert, update, delete, truncate on tables from anon;
```

Konsekvens: när en migration skapar en ny tabell **ärver anon ingen
skrivrättighet**. SELECT ärvs fortfarande via schema-defaultet (och kan
strypas av RLS på tabellen).

Det betyder att en migration som skapar en tabell som anon LEGITIMT ska
kunna skriva mot måste själv lägga på granten explicit — annars svarar
PostgREST med 401 så fort frontenden försöker skriva. Två existerande
exempel:

```sql
grant insert on public.trial_signups to anon;  -- onboarding-flödet
grant insert on public.subscribers   to anon;  -- nyhetsbrev-signup
```

**Regel:** i varje ny migration som skapar en tabell, avsluta med en
grant-block där anon-behörigheter listas explicit (eller kommenteras
bort som "avsiktligt inga anon-grants"). Då syns intentionen i git och
policyn dokumenterar sig själv.

**Undantag:** service_role bypasser både grants och RLS. Edge functions
som kör med SERVICE_ROLE_KEY (daily-fetch, pipeline, backfill-*,
synthesize, etc.) berörs inte.

## Migration-ordning: apply före add-constraint

`20260715160000_processing_queue_status_done_constraint.sql` fick lära
oss det hårda vägen. Om en migration lägger på en check-constraint på
existerande data, kör cleanup i en tidigare migration (eller manuellt
före apply) — annars misslyckas ADD CONSTRAINT med violation.
