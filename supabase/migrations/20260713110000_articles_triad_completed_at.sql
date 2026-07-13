-- articles.triad_completed_at: när TRIAD-innehåll faktiskt landade på raden.
-- Sätts av _shared/labeled-triad.ts fieldsToDbUpdate() så alla tre writers
-- (pipeline, triad-background, triad-on-demand) plockar upp den utan att
-- veta om det — en källa till sanning för "TRIAD skrivet".
--
-- Existerande 9 234 rader lämnas NULL. Vi vet inte när de skrevs; att
-- gissa (t.ex. = fetched_at) skulle blanda hämtning med analys och
-- skapa en vänlig lögn av det slag som gjorde att synteserna såg
-- friska ut i 8 dagar (2026-07-05..2026-07-13). NULL betyder "vi vet inte" —
-- det är sanningen. Väktarens triad_takt_24h börjar på 0 och stiger
-- naturligt när nya writes landar.

alter table public.articles add column triad_completed_at timestamptz;

comment on column public.articles.triad_completed_at is
  'When TRIAD content was written to this row. Set by _shared/labeled-triad.ts fieldsToDbUpdate(). NULL for rows written before 2026-07-13 — historical write time is unknowable and refused to fabricate.';
