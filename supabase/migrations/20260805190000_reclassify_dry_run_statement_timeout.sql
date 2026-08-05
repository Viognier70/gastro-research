-- =============================================================================
-- reclassify_dry_run: statement_timeout = 15min (2026-08-05)
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- SQL-editorns proxy tar Failed-to-fetch på reclassify_dry_run('gastronomy',
-- 0, 'b'/'c'/'d') — title-matchningen (3.8M substring-sökningar) tar längre
-- än editorns default timeout tål. REST-API:et via service_role (t.ex.
-- scripts/reclassify-dry-run.ts) har längre proxy-tolerans; det räcker för
-- editorns limit att INTE också vara statement_timeout-limit på funktionen.
--
-- Sätter 15 min direkt på funktionen — skyddar oavsett anropsväg. Endast
-- diagnostikfunktion, körs sällan, ingen risk för produktions-workloads.
-- =============================================================================

alter function public.reclassify_dry_run(text, int, text)
  set statement_timeout = '15min';


-- Verifiering:
--   select proname, prosrc, proconfig
--     from pg_proc where proname = 'reclassify_dry_run';
--   -- proconfig ska innehålla 'statement_timeout=15min'
