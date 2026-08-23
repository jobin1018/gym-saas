-- Schedule daily-owner-brief to run daily at 07:00 Asia/Kolkata.
--
-- ============================================================================
-- 07:00 IST IS '30 1 * * *' — VERIFIED, NOT ASSUMED
-- ============================================================================
-- pg_cron evaluates schedules in the timezone named by `cron.timezone`. On this
-- instance that was checked directly:
--
--   postgres=# SHOW cron.timezone;
--    cron.timezone
--   ---------------
--    GMT
--
-- IST is UTC+05:30 with no DST, so 07:00 IST is 01:30 UTC every day of the
-- year: `30 1 * * *`. Re-check with `SHOW cron.timezone;` on your hosted
-- project before trusting this there — if it is not GMT/UTC, recompute the
-- expression rather than copying it.
--
-- `0 7 * * *` would fire at 12:30 IST, in the middle of the afternoon.
--
-- The 07:00 local target is also load-bearing for correctness, not just
-- politeness: daily-owner-brief resolves each organization's calendar day in
-- ITS OWN timezone (locations.timezone) before counting yesterday's check-ins.
-- A 07:00 IST run sits safely clear of the 00:00–05:30 IST window where the UTC
-- date and the IST date disagree.
--
-- ============================================================================
-- THIS SHARES ITS SLOT WITH renewal-scan — deliberately, and safely
-- ============================================================================
-- "renewal-scan-daily" also fires at 01:30 UTC. There is no ordering dependency
-- between them: renewal-scan is read-only with respect to memberships (it only
-- calls send-renewal-reminder), so it cannot change any figure this brief
-- reports. The two jobs are independent and either order is correct.
--
-- If you would rather the brief's "messages failed to send" count include the
-- reminder batch from the same morning, move this job fifteen minutes later:
--   select cron.alter_job(
--     (select jobid from cron.job where jobname = 'daily-owner-brief'),
--     schedule => '45 1 * * *');
--
-- ============================================================================
-- LOCAL vs DEPLOYED
-- ============================================================================
-- This migration reuses the SAME two Vault secrets that
-- 20260823130500_schedule_renewal_scan_cron.sql introduced — `project_url` and
-- `service_role_key`. If you already set them for renewal-scan, there is
-- nothing new to do here.
--
--   LOCAL   project_url      = 'http://kong:8000'
--                              (NOT http://127.0.0.1:54321 — the cron job runs
--                              INSIDE the database container, where 127.0.0.1
--                              is the database itself.)
--           service_role_key = SERVICE_ROLE_KEY from `supabase status`
--           `supabase db reset` wipes Vault, so re-set both after every reset.
--
--   DEPLOYED project_url     = 'https://<project-ref>.supabase.co'
--           service_role_key = Dashboard -> Settings -> API Keys
--           Plus: pg_cron and pg_net enabled under Database -> Extensions, and
--                supabase functions deploy daily-owner-brief
--           Until the function is deployed the job fires fine and gets a 404.
--
--   select vault.create_secret('http://kong:8000',   'project_url');
--   select vault.create_secret('<service-role-key>', 'service_role_key');
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- ---------------------------------------------------------------------------
-- The job body, as a function rather than an inline string — same three reasons
-- as trigger_renewal_scan(): it can be run by hand, a missing Vault secret
-- becomes a readable WARNING instead of a null-argument failure every morning,
-- and changing the payload later is an ordinary migration.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trigger_daily_owner_brief(payload jsonb DEFAULT '{}'::jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
-- Pinned search_path: this is SECURITY DEFINER and reads Vault, so it must not
-- resolve `net.` or `vault.` through a caller-controlled search_path.
SET search_path = public, extensions, vault, pg_temp
AS $$
DECLARE
  v_url text;
  v_key text;
  v_req bigint;
BEGIN
  SELECT decrypted_secret INTO v_url
    FROM vault.decrypted_secrets WHERE name = 'project_url';
  SELECT decrypted_secret INTO v_key
    FROM vault.decrypted_secrets WHERE name = 'service_role_key';

  IF v_url IS NULL OR v_key IS NULL THEN
    RAISE WARNING
      'trigger_daily_owner_brief: missing Vault secret(s) — project_url=%, service_role_key=%. '
      'Set them with vault.create_secret(); see 20260823140500_schedule_daily_owner_brief_cron.sql.',
      coalesce(v_url, '<unset>'),
      CASE WHEN v_key IS NULL THEN '<unset>' ELSE '<set>' END;
    RETURN NULL;
  END IF;

  SELECT net.http_post(
    url     := rtrim(v_url, '/') || '/functions/v1/daily-owner-brief',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 -- daily-owner-brief requires the SERVICE ROLE key
                 -- specifically, not just any valid JWT. See _shared/auth.ts.
                 'Authorization', 'Bearer ' || v_key
               ),
    body    := payload,
    -- The brief runs a handful of small aggregate queries per organization and
    -- calls no external API, so it is far quicker than renewal-scan. Generous
    -- anyway: pg_net is fire-and-forget, and this governs how long its worker
    -- waits for the RESPONSE, not whether the run happens.
    timeout_milliseconds := 120000
  ) INTO v_req;

  RETURN v_req;
END;
$$;

-- SECURITY DEFINER + Vault access means EXECUTE on this function is equivalent
-- to holding the service role key. Default EXECUTE is granted to PUBLIC, so it
-- has to be revoked explicitly — otherwise any authenticated end user could
-- make every gym owner's phone buzz on demand.
REVOKE ALL ON FUNCTION public.trigger_daily_owner_brief(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trigger_daily_owner_brief(jsonb) FROM anon, authenticated;

COMMENT ON FUNCTION public.trigger_daily_owner_brief(jsonb) IS
  'Fires the daily-owner-brief Edge Function via pg_net. Called daily by the '
  '"daily-owner-brief" cron job at 01:30 UTC (07:00 IST). Pass {"dry_run":true} '
  'to exercise the wiring without sending anything.';

-- ---------------------------------------------------------------------------
-- The schedule
-- ---------------------------------------------------------------------------
-- Unschedule first so the migration is re-runnable and so changing the
-- expression later cannot leave two jobs firing.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'daily-owner-brief') THEN
    PERFORM cron.unschedule('daily-owner-brief');
  END IF;
END;
$$;

SELECT cron.schedule(
  'daily-owner-brief',
  '30 1 * * *',                      -- 01:30 UTC = 07:00 Asia/Kolkata
  $$SELECT public.trigger_daily_owner_brief();$$
);

-- ---------------------------------------------------------------------------
-- FAILURE VISIBILITY — the same caveat as renewal-scan, and it matters more here
-- ---------------------------------------------------------------------------
-- pg_net is asynchronous. cron.job_run_details records this job as 'succeeded'
-- as soon as the request is QUEUED, so a 401, a 404 (function not deployed) or
-- a 500 from the run all look like success from cron's side. Worse for this
-- job than for renewal-scan: nobody complains about a brief that never arrived
-- the way they complain about a missing payment link, so a silently broken
-- morning brief can go unnoticed for weeks.
--
--   -- did the job fire?
--   select jobid, runid, status, return_message, start_time
--     from cron.job_run_details
--    where jobid = (select jobid from cron.job where jobname = 'daily-owner-brief')
--    order by start_time desc limit 10;
--
--   -- what did daily-owner-brief actually answer?
--   select id, status_code,
--          content::jsonb -> 'sent'    as sent,
--          content::jsonb -> 'errored' as errored,
--          created as at
--     from net._http_response
--    order by created desc limit 10;
--
-- net._http_response is pruned automatically (a few hours by default), so it is
-- a debugging surface, not an audit log. The durable record of which owner was
-- briefed on which day is the whatsapp_messages rows themselves:
--
--   select organization_id, created_at, body_preview
--     from whatsapp_messages
--    where template_name = 'daily_owner_brief'
--    order by created_at desc limit 20;
--
-- To test the whole chain right now without waiting for 07:00:
--   select public.trigger_daily_owner_brief('{"dry_run":true}'::jsonb);
--   -- then read net._http_response as above
--
-- To pause the job without dropping this migration's work:
--   update cron.job set active = false where jobname = 'daily-owner-brief';
