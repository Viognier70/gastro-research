-- =====================================================================
-- Phase 3 tail — rate limit for semantic-search edge function
-- =====================================================================
-- Free (anon + non-Pro authed) callers: 3 searches per UTC day.
-- Pro callers: unlimited (edge fn skips the gate).
--
-- Identity keying:
--   * authenticated user  → user.id::text (from Authorization Bearer JWT)
--   * anon                → client-generated UUID stored in localStorage
--                           and sent in the request body as `anonId`
--   IP is not used — Deno edge runtime does not surface a reliable one.
--
-- The table + the record_search_usage RPC are called only by the edge
-- function using the service_role key. Anon/authenticated have no direct
-- access; RLS + no grants keeps the table invisible over REST.
-- =====================================================================

create table if not exists public.search_usage (
  id uuid primary key default gen_random_uuid(),
  identity   text        not null,     -- user_id::text or anon-uuid
  is_authed  boolean     not null default false,
  used_on    date        not null default (now() at time zone 'utc')::date,
  count      int         not null default 1,
  created_at timestamptz not null default now(),
  unique (identity, used_on)
);

create index if not exists search_usage_used_on_idx
  on public.search_usage (used_on);

alter table public.search_usage enable row level security;
-- Intentionally no policy → anon/authenticated cannot read or write via
-- REST. service_role bypasses RLS, which is how the edge function reaches
-- the row through the RPC below.

revoke all on table public.search_usage from anon, authenticated;

-- ---------------------------------------------------------------------
-- Atomic upsert-and-increment. Returns the new count for this identity
-- + today. Called only from the edge function with the service_role key
-- (which bypasses grants); revoked from public so nothing else can call
-- it accidentally through PostgREST.
-- ---------------------------------------------------------------------
create or replace function public.record_search_usage(
  p_identity  text,
  p_is_authed boolean
)
returns int
language sql
security definer
set search_path = public
as $$
  insert into public.search_usage (identity, is_authed, used_on, count)
  values (p_identity, coalesce(p_is_authed, false),
          (now() at time zone 'utc')::date, 1)
  on conflict (identity, used_on)
  do update set count = public.search_usage.count + 1
  returning count;
$$;

revoke all on function public.record_search_usage(text, boolean) from public;
-- No grant to authenticated or anon. service_role bypasses grants.

-- ---------------------------------------------------------------------
-- Verification queries you can run after apply:
--   select has_table_privilege('anon',          'public.search_usage', 'SELECT'); -- false
--   select has_table_privilege('authenticated', 'public.search_usage', 'SELECT'); -- false
--   select has_function_privilege('anon',          'public.record_search_usage(text, boolean)', 'EXECUTE'); -- false
--   select has_function_privilege('authenticated', 'public.record_search_usage(text, boolean)', 'EXECUTE'); -- false
-- The edge function uses SUPABASE_SERVICE_ROLE_KEY, which bypasses both.
-- =====================================================================
