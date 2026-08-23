-- Schedule renewal-scan to run daily at 07:00 Asia/Kolkata.
--
-- ============================================================================
-- 07:00 IST IS '30 1 * * *' — THE SCHEDULE IS IN UTC, NOT IST
-- ============================================================================
-- pg_cron evaluates its schedules in the timezone named by `cron.timezone`,
-- which on Supabase is UTC. IST is UTC+05:30 and has no DST, so 07:00 IST is
-- 01:30 UTC every day of the year: `30 1 * * *`.
--
-- Do NOT "fix" this to `0 7 * * *` — that would fire at 12:30 IST, in the
-- middle of the afternoon. Check what your instance is actually set to with:
--   SHOW cron.timezone;
-- and if it is not UTC, recompute the expression rather than assuming.
--
-- The 07:00 local target also matters for correctness, not just politeness:
-- renewal-scan resolves "today" in BILLING_TIMEZONE (Asia/Kolkata) before
-- computing its target dates. A 07:00 IST run is safely clear of the 00:00–05:30
-- IST window where the UTC date and the IST date disagree.
--
-- ============================================================================
-- LOCAL vs DEPLOYED — this migration is written to work in both
-- ============================================================================
-- Nothing below hardcodes a URL or a key. Both are read from Vault at RUN time,
-- so the same migration produces a job that targets local containers on a local
-- reset and your real project once deployed. What you must set differs:
--
--   LOCAL   project_url      = 'http://kong:8000'
--                              (NOT http://127.0.0.1:54321 — the cron job runs
--                              INSIDE the database container, where 127.0.0.1 is
--                              the database itself. 'kong' is the API gateway's
--                              name on the compose network.)
--           service_role_key = the SERVICE_ROLE_KEY from `supabase status`
--           NOTE: `supabase db reset` wipes Vault along with everything else, so
--           these have to be re-set after every reset. That is also why they are
--           not in seed.sql — a service role key does not belong in git.
--
--   DEPLOYED project_url     = 'https://<project-ref>.supabase.co'
--           service_role_key = the service role key from
--                              Dashboard -> Settings -> API Keys
--           Set these ONCE in the SQL editor. Also confirm pg_cron and pg_net
--           are enabled under Database -> Extensions, and that the function is
--           actually deployed:
--                supabase functions deploy renewal-scan
--                supabase functions deploy send-renewal-reminder
--           Until the function is deployed the job runs fine and simply gets a
--           404 back — see the note on failure visibility at the bottom.
--
-- To set them (either environment):
--   select vault.create_secret('http://kong:8000',       'project_url');
--   select vault.create_secret('<service-role-key>',     'service_role_key');
-- To change one later:
--   select vault.update_secret(
--     (select id from vault.secrets where name = 'project_url'),
--     'https://<project-ref>.supabase.co');
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- ---------------------------------------------------------------------------
-- The job body, as a function rather than an inline string.
--
-- Three reasons this is not just pasted into cron.schedule():
--   1. It can be run by hand — `select public.trigger_renewal_scan();` — to
--      test the wiring without waiting until 07:00.
--   2. A missing Vault secret becomes a clear WARNING instead of a cron job
--      that fails every morning with a null-argument error nobody reads.
--   3. Changing the payload later is an ordinary migration, not a re-schedule.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trigger_renewal_scan(payload jsonb DEFAULT '{}'::jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
-- Pinned search_path: this is SECURITY DEFINER and reads Vault, so it must not
-- resolve `net.` or `vault.` through a caller-controlled search_path.
SET search_path = public, extensions, vault, pg_temp
AS $$
DECLARE
  v_url  text;
  v_key  text;
  v_req  bigint;
BEGIN
  SELECT decrypted_secret INTO v_url
    FROM vault.decrypted_secrets WHERE name = 'project_url';
  SELECT decrypted_secret INTO v_key
    FROM vault.decrypted_secrets WHERE name = 'service_role_key';

  IF v_url IS NULL OR v_key IS NULL THEN
    RAISE WARNING
      'trigger_renewal_scan: missing Vault secret(s) — project_url=%, service_role_key=%. '
      'Set them with vault.create_secret(); see 20260823130500_schedule_renewal_scan_cron.sql.',
      coalesce(v_url, '<unset>'),
      CASE WHEN v_key IS NULL THEN '<unset>' ELSE '<set>' END;
    RETURN NULL;
  END IF;

  SELECT net.http_post(
    url     := rtrim(v_url, '/') || '/functions/v1/renewal-scan',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 -- renewal-scan requires the SERVICE ROLE key specifically, not
                 -- just any valid JWT. See _shared/auth.ts.
                 'Authorization', 'Bearer ' || v_key
               ),
    body    := payload,
    -- Generous, because the scan is sequential and paced (250ms between
    -- reminders) — a 100-membership batch can legitimately take a minute or
    -- more. pg_net is fire-and-forget regardless: this timeout governs how long
    -- its background worker waits for the RESPONSE, not whether the scan runs.
    timeout_milliseconds := 300000
  ) INTO v_req;

  RETURN v_req;
END;
$$;

-- SECURITY DEFINER + Vault access means EXECUTE on this function is equivalent
-- to holding the service role key. Default EXECUTE is granted to PUBLIC, so it
-- has to be revoked explicitly — otherwise any authenticated end user could
-- trigger a billing run.
REVOKE ALL ON FUNCTION public.trigger_renewal_scan(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trigger_renewal_scan(jsonb) FROM anon, authenticated;

COMMENT ON FUNCTION public.trigger_renewal_scan(jsonb) IS
  'Fires the renewal-scan Edge Function via pg_net. Called daily by the '
  '"renewal-scan-daily" cron job at 01:30 UTC (07:00 IST). Pass {"dry_run":true} '
  'to exercise the wiring without sending anything.';

-- ---------------------------------------------------------------------------
-- The schedule
-- ---------------------------------------------------------------------------
-- Unschedule first so the migration is re-runnable and so changing the
-- expression later cannot leave two jobs firing.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'renewal-scan-daily') THEN
    PERFORM cron.unschedule('renewal-scan-daily');
  END IF;
END;
$$;

SELECT cron.schedule(
  'renewal-scan-daily',
  '30 1 * * *',                      -- 01:30 UTC = 07:00 Asia/Kolkata
  $$SELECT public.trigger_renewal_scan();$$
);

-- ---------------------------------------------------------------------------
-- FAILURE VISIBILITY — read this before trusting the job
-- ---------------------------------------------------------------------------
-- pg_net is asynchronous. cron.job_run_details will record this job as
-- 'succeeded' as soon as the request is QUEUED, which means a 401, a 404 (the
-- function is not deployed yet) or a 500 from the scan all look like success
-- from cron's side. The HTTP response lands separately:
--
--   -- did the job fire?
--   select jobid, runid, status, return_message, start_time
--     from cron.job_run_details
--    where jobid = (select jobid from cron.job where jobname = 'renewal-scan-daily')
--    order by start_time desc limit 10;
--
--   -- what did renewal-scan actually answer?
--   select id, status_code, content::jsonb -> 'created' as created,
--          content::jsonb -> 'errored' as errored, created as at
--     from net._http_response
--    order by created desc limit 10;
--
-- net._http_response is pruned automatically (a few hours by default), so it is
-- a debugging surface, not an audit log. The durable record of what a scan did
-- is the payments and whatsapp_messages rows send-renewal-reminder wrote.
--
-- To test the whole chain right now without waiting for 07:00:
--   select public.trigger_renewal_scan('{"dry_run":true}'::jsonb);
--   -- then read net._http_response as above
--
-- To pause the job without dropping this migration's work:
--   update cron.job set active = false where jobname = 'renewal-scan-daily';
