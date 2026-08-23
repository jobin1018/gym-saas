-- Schedule mark-overdue to run daily at 06:45 Asia/Kolkata.
--
-- ============================================================================
-- 06:45 IST IS '15 1 * * *' — VERIFIED, NOT ASSUMED
-- ============================================================================
-- pg_cron evaluates schedules in the timezone named by `cron.timezone`, which
-- was checked directly on this instance rather than assumed:
--
--   postgres=# select current_setting('cron.timezone');
--    GMT
--
--   postgres=# select timestamptz '2026-08-23 01:15:00+00' at time zone 'Asia/Kolkata';
--    2026-08-23 06:45:00
--
-- So `15 1 * * *` fires at 06:45 IST. Re-check with `SHOW cron.timezone;` on
-- your hosted project before trusting this there.
--
-- ============================================================================
-- THE ORDERING IS THE WHOLE POINT — 15 MINUTES AHEAD OF THE OTHER TWO
-- ============================================================================
--   06:45 IST (01:15 UTC)  mark-overdue        writes memberships.status
--   07:00 IST (01:30 UTC)  renewal-scan        READS memberships.status
--   07:00 IST (01:30 UTC)  daily-owner-brief   READS memberships.status
--
-- Both 07:00 jobs are consumers of the column this job maintains:
--   - daily-owner-brief's Overdue figure counts lapsed memberships. It reads
--     status IN ('active','past_due'), so it is correct either way — but the
--     status column it reports on is only trustworthy once this has run.
--   - renewal-scan's dunning offsets (-3, -7, when enabled) have past_due as a
--     precondition. Before this job existed they could never match anything.
--
-- Fifteen minutes is deliberately generous: mark-overdue does a handful of
-- indexed UPDATEs and finishes in well under a second on any realistic tenant
-- count, so the gap is slack for a slow morning, not a measured requirement.
--
-- If you ever need to reorder, keep this one FIRST. Running it after the
-- readers means every owner's brief and every dunning reminder is working from
-- yesterday's status for a full day.
--
-- ============================================================================
-- LOCAL vs DEPLOYED
-- ============================================================================
-- Reuses the SAME two Vault secrets as the other two cron migrations —
-- `project_url` and `service_role_key`. If they are already set, there is
-- nothing new to do here.
--
--   LOCAL   project_url      = 'http://kong:8000'
--                              (NOT 127.0.0.1:54321 — the job runs INSIDE the
--                              database container.)
--           service_role_key = SERVICE_ROLE_KEY from `supabase status`
--           `supabase db reset` wipes Vault; re-set both after every reset.
--
--   DEPLOYED project_url     = 'https://<project-ref>.supabase.co'
--           service_role_key = Dashboard -> Settings -> API Keys
--           Plus pg_cron/pg_net enabled, and:
--                supabase functions deploy mark-overdue
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- ---------------------------------------------------------------------------
-- The job body, as a function — same three reasons as the other two triggers:
-- runnable by hand, a missing Vault secret becomes a readable WARNING instead
-- of a null-argument failure every morning, and changing the payload later is
-- an ordinary migration rather than a re-schedule.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trigger_mark_overdue(payload jsonb DEFAULT '{}'::jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
-- Pinned search_path: SECURITY DEFINER reading Vault must not resolve `net.` or
-- `vault.` through a caller-controlled search_path.
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
      'trigger_mark_overdue: missing Vault secret(s) — project_url=%, service_role_key=%. '
      'Set them with vault.create_secret(); see 20260823150500_schedule_mark_overdue_cron.sql.',
      coalesce(v_url, '<unset>'),
      CASE WHEN v_key IS NULL THEN '<unset>' ELSE '<set>' END;
    RETURN NULL;
  END IF;

  SELECT net.http_post(
    url     := rtrim(v_url, '/') || '/functions/v1/mark-overdue',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 -- mark-overdue requires the SERVICE ROLE key specifically, not
                 -- just any valid JWT. See _shared/auth.ts.
                 'Authorization', 'Bearer ' || v_key
               ),
    body    := payload,
    -- Indexed UPDATEs only, no external API calls — this is the fastest of the
    -- three jobs. Generous anyway; pg_net is fire-and-forget and this governs
    -- how long its worker waits for the RESPONSE, not whether the run happens.
    timeout_milliseconds := 120000
  ) INTO v_req;

  RETURN v_req;
END;
$$;

-- SECURITY DEFINER + Vault access means EXECUTE here is equivalent to holding
-- the service role key — and this function WRITES membership status, so an
-- unrevoked EXECUTE would let any authenticated end user mass-mark a tenant's
-- members past_due. Default EXECUTE is granted to PUBLIC, so revoke explicitly.
REVOKE ALL ON FUNCTION public.trigger_mark_overdue(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trigger_mark_overdue(jsonb) FROM anon, authenticated;

COMMENT ON FUNCTION public.trigger_mark_overdue(jsonb) IS
  'Fires the mark-overdue Edge Function via pg_net. Called daily by the '
  '"mark-overdue-daily" cron job at 01:15 UTC (06:45 IST), fifteen minutes '
  'before renewal-scan and daily-owner-brief read the status column it '
  'maintains. Pass {"dry_run":true} to exercise the wiring without writing.';

-- ---------------------------------------------------------------------------
-- The schedule
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'mark-overdue-daily') THEN
    PERFORM cron.unschedule('mark-overdue-daily');
  END IF;
END;
$$;

SELECT cron.schedule(
  'mark-overdue-daily',
  '15 1 * * *',                      -- 01:15 UTC = 06:45 Asia/Kolkata
  $$SELECT public.trigger_mark_overdue();$$
);

-- ---------------------------------------------------------------------------
-- FAILURE VISIBILITY — same pg_net caveat as the other two jobs
-- ---------------------------------------------------------------------------
-- pg_net is asynchronous. cron.job_run_details records this job as 'succeeded'
-- as soon as the request is QUEUED, so a 401, a 404 (function not deployed) or
-- a 500 from the run all look like success from cron's side.
--
-- This job fails the most quietly of the three. A broken renewal-scan means
-- members stop getting payment links and someone notices within a day; a broken
-- mark-overdue means every Overdue figure silently reads zero and every dunning
-- offset silently matches nothing — which is exactly the failure mode that made
-- this function necessary in the first place.
--
--   -- did the job fire?
--   select jobid, runid, status, return_message, start_time
--     from cron.job_run_details
--    where jobid = (select jobid from cron.job where jobname = 'mark-overdue-daily')
--    order by start_time desc limit 10;
--
--   -- what did mark-overdue actually answer?
--   select id, status_code,
--          content::jsonb -> 'transitioned' as transitioned,
--          content::jsonb -> 'errored'      as errored,
--          created as at
--     from net._http_response
--    order by created desc limit 10;
--
-- The durable check that does not depend on pg_net at all — if this is ever
-- non-zero during the working day, the job is not running:
--
--   select count(*) from memberships
--    where status = 'active' and current_period_end < CURRENT_DATE;
--
-- To test the whole chain right now without waiting for 06:45:
--   select public.trigger_mark_overdue('{"dry_run":true}'::jsonb);
--
-- To pause without dropping this migration's work:
--   update cron.job set active = false where jobname = 'mark-overdue-daily';
