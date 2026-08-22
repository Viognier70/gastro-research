-- =====================================================================
-- Ask-synth · daily hard-cap on Sonnet spend (B2-revideat, 2026-07-22)
-- =====================================================================
-- Separate from triad_budget_log (which caps TRIAD-Sonnet at 500/day).
-- ask-synth is a distinct cost center: query→answer synthesis called by
-- practitioners on Ask-vyn. This RPC gives it an isolated daily ceiling,
-- so runaway Pro use (bug, abuse, or unexpected volume) can't drain the
-- Anthropic budget silently.
--
-- Called only from supabase/functions/ask-synth/index.ts using
-- service_role. authenticated/anon have no direct access.
--
-- Env var ASK_DAILY_BUDGET on the edge fn passes the current cap; RPC
-- returns remaining count (or -1 = exceeded). Same interaction pattern
-- as triad_budget_claim so ops muscle-memory is preserved.
-- =====================================================================

create table if not exists public.ask_budget_log (
  day        date primary key default current_date,
  count      int not null default 0,
  created_at timestamptz not null default now()
);

create or replace function public.ask_budget_claim(p_budget integer)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_count int;
begin
  insert into public.ask_budget_log (day, count)
       values (current_date, 1)
  on conflict (day) do update
     set count = ask_budget_log.count + 1
     where ask_budget_log.count < p_budget
  returning count into v_count;

  if v_count is null then return -1; end if;
  return p_budget - v_count;
end
$function$;

revoke all on function public.ask_budget_claim(integer) from public, anon, authenticated;
grant execute on function public.ask_budget_claim(integer) to service_role;

-- Verifiering efter apply:
--   select has_function_privilege('anon',          'public.ask_budget_claim(integer)', 'EXECUTE'); -- false
--   select has_function_privilege('authenticated', 'public.ask_budget_claim(integer)', 'EXECUTE'); -- false
--   select public.ask_budget_claim(100); -- första körning: 99
--   select * from public.ask_budget_log where day = current_date; -- count=1
